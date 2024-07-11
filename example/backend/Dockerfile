FROM hexpm/elixir:1.15.7-erlang-26.2.2-alpine-3.19.1

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
