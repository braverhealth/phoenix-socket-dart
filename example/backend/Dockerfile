FROM bitwalker/alpine-elixir-phoenix

EXPOSE 4001

ADD mix.exs mix.lock ./
RUN mix do deps.get, deps.compile

ADD . .

CMD ["mix", "phx.server"]
