defmodule Natsex.Streaming.Client do
  @moduledoc """
  Client for NATS Streaming
  """

  use GenServer
  require Logger

  alias Natsex.Streaming.Messages

  @cluster_id "test-cluster"
  @connect_subject_prefix "_STAN.discover"

  @initial_state %{
    pid: nil,
    status: :disconnected,
    client_id: nil,
    server_info: nil,

    heartbeat: %{
      subject: nil,
      sub_sid: nil,
    },

    subs: %{
      publish: nil,
      sub: %{},
    },

    subscribers: %{},
    ack_inbox: %{},
    waiters: %{},
  }

  def publish(pid, subject, payload) do
    GenServer.call(pid, {:publish, subject, payload})
  end

  def subscribe(pid, subject, who) do
    GenServer.call(pid, {:subscribe, subject, who})
  end

  def unsubscribe(pid, subject) do
    GenServer.call(pid, {:unsubscribe, subject})
  end

  def ack(pid, subject, sequence) do
    GenServer.cast(pid, {:ack, subject, sequence})
  end

  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(_opts) do
    {:ok, pid} = Natsex.start_link(config: %{port: 4444})
    {:ok, %{@initial_state| pid: pid, client_id: UUID.uuid4()}, 0}
  end

  def handle_call({:publish, subject, payload}, from, state) do
    msg_id = UUID.uuid4()
    msg =
      Messages.PubMsg.encode(
        Messages.PubMsg.new(
          clientID: state.client_id,
          guid: msg_id,
          subject: subject,
          data: payload
        ))

    pub_subject = state.server_info.pubPrefix <> "." <> @cluster_id
    :ok = Natsex.publish(state.pid, pub_subject, msg, state.subs.publish)

    {:noreply, %{state| waiters: Map.put(state.waiters, msg_id, from)}}
  end

  def handle_call({:subscribe, subject, who}, from, state) do
    inbox = "streaming.sub.inbox." <> UUID.uuid4()
    Natsex.subscribe(state.pid, inbox, self())

    msg =
      Messages.SubscriptionRequest.encode(
        Messages.SubscriptionRequest.new(
          clientID: state.client_id,
          subject: subject,
          inbox: inbox,

          ackWaitInSecs: 5,
          maxInFlight: 5
        ))

    sub_subject = "streaming.sub.reply." <> UUID.uuid4()
    sid = Natsex.subscribe(state.pid, sub_subject, self())

    :ok = Natsex.publish(state.pid, state.server_info.subRequests, msg,
                         sub_subject)

    sub = Map.put(state.subs.sub, sub_subject, {sid, subject, from, who, inbox})

    {:noreply, %{state| subs: %{state.subs| sub: sub}}}
  end

  def handle_call({:unsubscribe, subject}, _from, state) do
    {ack_inbox, new_inbox} = Map.pop(state.ack_inbox, subject)
    if ack_inbox do
      msg =
        Messages.UnsubscribeRequest.encode(
          Messages.UnsubscribeRequest.new(
            clientID: state.client_id,
            subject: subject,
            inbox: ack_inbox
          ))

      Natsex.publish(state.pid, state.server_info.unsubRequests, msg)
    end

    {:reply, :ok, %{state| ack_inbox: new_inbox}}
  end

  def handle_call(:stop, _from, state) do
    msg =
      Messages.CloseRequest.encode(
        Messages.CloseRequest.new(
          clientID: state.client_id
        ))

    resp = request(state.pid, state.server_info.closeRequests, msg,
                   Messages.CloseResponse)
    %{error: ""} = resp

    {:reply, :ok, state}
  end

  def handle_cast({:ack, subject, sequence}, state) do
    msg =
      Messages.Ack.encode(
        Messages.Ack.new(
          subject: subject,
          sequence: sequence
        ))

    case Map.get(state.ack_inbox, subject) do
      nil ->
        Logger.error("Can'f find ack inbox for subject: #{inspect subject}")

      ack_inbox ->
        Natsex.publish(state.pid, ack_inbox, msg)
    end

    {:noreply, state}
  end

  def handle_info(:timeout, %{pid: pid, status: :disconnected} = state) do
    heartbeat_subject = "heartbeat." <> state.client_id
    heartbeat_sid = Natsex.subscribe(pid, heartbeat_subject, self())

    msg =
      Messages.ConnectRequest.encode(
        Messages.ConnectRequest.new(
          clientID: state.client_id,
          heartbeatInbox: heartbeat_subject
        ))

    resp = request(state.pid, @connect_subject_prefix <> "." <> @cluster_id,
                   msg, Messages.ConnectResponse)
    %{error: ""} = resp

    publish_subject = "streaming.pub." <> UUID.uuid4()
    Natsex.subscribe(pid, publish_subject, self())

    {:noreply, %{state| status: :connected, server_info: resp,
                        heartbeat: %{state.heartbeat|
                          subject: heartbeat_subject,
                          sub_sid: heartbeat_sid,
                        },
                        subs: %{state.subs|
                          publish: publish_subject}}}
  end

  def handle_info(
    {:natsex_message, {subject, sid, reply_to}, ""},
    %{heartbeat: %{subject: subject, sub_sid: sid}} = state) do

    Logger.debug("Streaming: heartbeat request")
    Natsex.publish(state.pid, reply_to, "")

    {:noreply, state}
  end

  def handle_info(
    {:natsex_message, {reply_subject, _sid, _reply_to}, proto_message},
    %{subs: %{publish: reply_subject}} = state) do

    msg = Messages.PubAck.decode(proto_message)
    Logger.debug("Streaming: publish response, #{inspect msg}")

    {client, new_waiters} = Map.pop(state.waiters, msg.guid)
    if client do
      GenServer.reply(client, msg)
    else
      Logger.warn("Can't find guid, message will be dropped")
    end

    {:noreply, %{state| waiters: new_waiters}}
  end

  def handle_info(
    {:natsex_message,
      {"streaming.sub.reply." <> _ = reply_subject, sid, _reply_to},
     proto_message},
    state) do

    msg = Messages.SubscriptionResponse.decode(proto_message)
    Logger.debug("Streaming: SubscriptionResponse response, #{inspect msg}")

    IO.inspect(state, label: "state")
    IO.inspect(reply_subject, label: "reply_subject")

    {resp, new_subs} = Map.pop(state.subs.sub, reply_subject)
    new_state =
      if resp do
        {sid, subject, client, who, inbox} = resp
        Natsex.unsubscribe(state.pid, sid)

        GenServer.reply(client, msg)
        %{state| ack_inbox: Map.put(state.ack_inbox, subject, msg.ackInbox),
                 subscribers: Map.put(state.subscribers, {subject, inbox}, who)}
      else
        Logger.warn("SubscriptionResponse: Can't find subject, message will be dropped")
        state
      end

    {:noreply, %{new_state| subs: %{new_state.subs| sub: new_subs}}}
  end

  def handle_info(
    {:natsex_message,
      {"streaming.sub.inbox." <> _ = reply_subject, _sid, _reply_to},
     proto_message},
    state) do

    msg = Messages.MsgProto.decode(proto_message)
    Logger.debug("Streaming.sub: new message, #{inspect msg}")

    case Map.get(state.subscribers, {msg.subject, reply_subject}) do
      nil ->
        Logger.warn("Cant find subscriber for pair
         {msg.subject, reply_subject}: #{inspect {msg.subject, reply_subject}}")
      who ->
        send(who, msg)
    end

    {:noreply, state}
  end

  def request(pid, subject, proto_msg, response_type) do
    {:ok, proto_response} = Natsex.request(pid, subject, proto_msg)
    resp = apply(response_type, :decode, [proto_response])

    IO.inspect(resp, label: "response")
    if resp.error != "" do
      Logger.error(resp.error)
    end

    # TODO: check error
    # %{error: ""} = resp

    resp
  end
end
