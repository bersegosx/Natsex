defmodule Natsex.ServerInfo do
  @moduledoc """
  Connection string parser
  """

  @spec parse(String.t) :: {String.t, pos_integer()|nil, String.t|nil, String.t|nil, String.t|nil}
  def parse(line) do
    u = URI.parse(line)

    {user, pass, token} =
      if u.userinfo =~ ":" do
        [user, pwd] = String.split(u.userinfo, ":", parts: 2)
        {user, pwd, nil}
      else
        {nil, nil, u.userinfo}
      end

    {u.host, u.port, user, pass, token}
  end
end
