## [0.4.2]

- Auto-reconnect when connection drops unexpectedly

## [0.4.1]

- Fix code analysis (from very_good_analysis) issues

## [0.4.0]

- Improve code readability and inline documentation
- Add ability to provide socket parameters

## [0.3.3]

- Fix closing of underlying websocket on PhoenixSocket close

## [0.3.2]

- Use quiver.async's StreamRouter to route messages to topic-specific streams

## [0.3.1]

- Fix bug where channels being closed by a socket would indirectly change the socket's 'channels' Map, leading to changes being concurrent to iteration, hence raising a StateError
- Do not try to send a 'leave' push if socket is closed anyway

## [0.3.0]

- Use dart:async Zone to isolate function calls that modify internal state.

## [0.2.5]

- Improved the internals quite a bit

## [0.2.4]

- Fix a couple of bugs around failing states

## [0.2.3]

- Fix duplicate message sending/completing in some race conditions

## [0.2.2]

- Make logging more configurable
- Fix auto-rejoin of channels

## [0.2.1]

- Add much more logging using the logging library
- Fix a couple of minor bugs

## [0.2.0]

- Fix some statement management issues
- Clean up classes file location
- Improve API to be more consistent with behavior

## [0.1.1]

- Add some very incomplete docs

## [0.1.0]

- First version that feel really stable
- Presence still largely untested
