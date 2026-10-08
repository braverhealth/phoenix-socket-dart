# Phoenix long-poll reference

`longpoll.js` is copied unchanged from Phoenix v1.8.15, commit
`bd1801833b4fd7ceb02497cc7ba2d05e9bd391c8`:
https://github.com/phoenixframework/phoenix/blob/v1.8.15/assets/js/phoenix/longpoll.js

Its MIT license is included. The Node harness replaces only imports and the
module export when evaluating this file; timers and Ajax are controlled by
the harness. Protocol logic runs directly from the upstream source.

From the core package, regenerate or verify the portable Dart fixtures with:

```sh
node tool/long_poll_reference.mjs
node tool/long_poll_reference.mjs --check
```

The generated expectations are used by both VM and headless Chrome tests.
