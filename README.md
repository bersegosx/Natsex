# Natsex

[![Build Status][shield-travis]][travis-ci]
[![Version][shield-version]][hexpm]
[![Coverage](https://codecov.io/gh/bersegosx/Natsex/branch/master/graph/badge.svg)][codecov]
[![License][shield-license]][hexpm]

> Elixir client for [NATS](https://nats.io/)

## Features

- Pub/Sub
- Request/Reply
- Queueing
- Keep-alive mechanism (via ping/pong)
- Reconnection logic
- TLS support
- Raw [NATS Streaming support](https://github.com/bersegosx/Natsex/tree/feature/streaming)

## Installation

The package can be installed by adding `natsex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:natsex, "~> 0.9.0"}
  ]
end
```

## Usage

```elixir
# connects with default params, host - "localhost", port - 4222
iex(1)> {:ok, pid} = Natsex.start_link()
{:ok, #PID<0.195.0>}

# or connects on custom port with credentials
iex(1)> {:ok, pid} = Natsex.start_link(config: %{host: "localhost", port: 4567, user: "admin", pass: "12345"})
{:ok, #PID<0.195.0>}

iex(2)> Natsex.subscribe(pid, "telegram.user.notifications", self())
"13b2d0cd-9dba-43b6-bb5d-288d48346ff4"

iex(3)> flush
{:natsex_message,
 {"telegram.user.notifications", "13b2d0cd-9dba-43b6-bb5d-288d48346ff4", nil},
 "Good news, everyone!"}
:ok

# sent a message and waits a response, aka "Request-Reply"
iex(4)> Natsex.request(pid, "questions", "sup?")
{:ok, "response"}

iex(5)> Natsex.stop(pid)
:ok
```

## TLS connection

```elixir
# connects with tls
iex(1)> Natsex.start_link(config: %{tls_required: true})
{:ok, #PID<0.195.0>}

# connects with client cert
iex(1)> Natsex.start_link(config: %{tls_required: true,
                                    cert_path: Path.expand("./cert.crt"),
                                    cert_key_path: Path.expand("./client.key")})
{:ok, #PID<0.195.0>}
```

## Benchmarking

| Name             |         ips |    average |   deviation |  median |  99th % |
|------------------|------------:|-----------:|------------:|     ---:|     ---:|
| parse-128        |   372.53 K  |    2.68 μs |   ±1421.03% |    2 μs |   12 μs |
| pub - 128        |    15.96 K  |   62.67 μs |     ±30.65% |   59 μs |  111 μs |
| sub-unsub-pub-16 |     4.45 K  |  224.69 μs |     ±47.88% |  210 μs |  449 μs |
| request/reply    |     3.60 K  |  277.94 μs |     ±18.10% |  262 μs |  448 μs |


## TODO

- [ ] String config (`nats://user:password@server:port`)
- [ ] Set the Number of Reconnect Attempts
- [ ] Cache outgoing data
- [ ] Avoiding the Thundering Herd
- [ ] Buffering Messages During Reconnect Attempts
- [ ] Setting the Connection Name
- [ ] Limit Outgoing Pings
- [ ] Cluster support

[shield-version]:   https://img.shields.io/hexpm/v/natsex.svg
[shield-license]:   https://img.shields.io/hexpm/l/natsex.svg
[shield-travis]:    https://travis-ci.org/bersegosx/Natsex.svg?branch=master

[travis-ci]:        https://travis-ci.org/bersegosx/Natsex
[hexpm]:            https://hex.pm/packages/natsex
[hexdocs]:          https://hexdocs.pm/natsex
[codecov]:          https://codecov.io/gh/bersegosx/Natsex
