# Natsex

[![Build Status][shield-travis]][travis-ci]
[![Version][shield-version]][hexpm]
[![Coverage](https://codecov.io/gh/bersegosx/Natsex/branch/master/graph/badge.svg)][codecov]
[![License][shield-license]][hexpm]

> Elixir client for [NATS](https://nats.io/)

## Installation

The package can be installed by adding `natsex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:natsex, "~> 0.2.1"}
  ]
end
```

## Usage

```elixir
# connects with default params, host - "localhost", port - 4222
iex(1)> Natsex.start_link
{:ok, #PID<0.178.0>}

# or connects on custom port with credentials
iex(1)> Natsex.start_link(%{host: "localhost", port: 4567, user: "admin", pass: "12345"})
{:ok, #PID<0.195.0>}

iex(2)> Natsex.subscribe "telegram.user.notifications", self
"13b2d0cd-9dba-43b6-bb5d-288d48346ff4"

iex(3)> flush
{:natsex_message,
 {"telegram.user.notifications", "13b2d0cd-9dba-43b6-bb5d-288d48346ff4", nil},
 "Good news, everyone!"}
:ok
```

## Documentation
Docs can be found at [hexdocs][hexdocs].

<br>

[shield-version]:   https://img.shields.io/hexpm/v/natsex.svg
[shield-license]:   https://img.shields.io/hexpm/l/natsex.svg
[shield-travis]:    https://travis-ci.org/bersegosx/Natsex.svg?branch=master

[travis-ci]:        https://travis-ci.org/bersegosx/Natsex
[hexpm]:            https://hex.pm/packages/natsex
[hexdocs]:          https://hexdocs.pm/natsex
[codecov]:          https://codecov.io/gh/bersegosx/Natsex
