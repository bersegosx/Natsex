defmodule Natsex.Streaming.Messages do
  use Protobuf, from: Path.expand("./proto/protocol.proto", __DIR__)
end
