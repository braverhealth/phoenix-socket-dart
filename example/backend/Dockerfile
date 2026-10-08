FROM hexpm/elixir:1.19.5-erlang-27.3.4-alpine-3.22.4

RUN apk update && apk upgrade && \
    apk add --no-cache \
        ca-certificates \
        bash \
        curl \
        git

RUN echo America/Montreal > /etc/timezone
RUN mix local.hex --force && \
    mix local.rebar --force

EXPOSE 4001

ADD mix.exs mix.lock ./
RUN mix do deps.get, deps.compile

ADD . .

CMD ["mix", "phx.server"]
