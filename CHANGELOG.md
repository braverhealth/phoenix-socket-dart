## [0.6.4.]

- Republish of 0.6.3 with actual fix

## [0.6.3.]

- Fix Push.future not completing in certain conditions

## [0.6.2.]

- Throw exception when sending messages when channel is closed

## [0.6.1.]

- Fix bug when reconnecting
- Prevent adding events to stream controllers when closed

## [0.6.0.]

- Fix race condition where heartbeats were added in a closed sink

## [0.5.3.]

- Minor optimizations
- Improve debugging

## [0.5.2.]

- Fix bug in `PhoenixChannelEvent.isReply`
- Replace `print` call with `Logger.severe`

## [0.5.1.]

- Fix re-connection issue

## [0.5.0]

- Add sound null safety

## [0.4.11]

- Fix a channel re-join issue (#20)

## [0.4.10]

- Make sure Push instances trigger only one event, and only once (#18)

## [0.4.9]

- Bugfix (#15)

## [0.4.8]

- Bugfix (#13 @carlosmobile)

## [0.4.7]

- Improve typing of channel parameters (#12 @carlosmobile)

## [0.4.6]

- Improve error handling on initial socket connection

## [0.4.5]

- Add readme.md to example/
- Improve handling of errors raised when Flutter app is put in background

## [0.4.4]

- Add simple flutter example
- Get rid of Zone (introduced in 0.3.0)
- Further improve error handling (fixed #5 and #6) and reconnection

## [0.4.3]

- Improve error handling

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
