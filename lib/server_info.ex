defmodule Natsex.ServerInfo do
  def parse(line) do
    u = URI.parse(line)
    [user, pwd] = String.split(u.userinfo, ":", parts: 2)
    {u.host, u.port, user, pwd}
  end
end
