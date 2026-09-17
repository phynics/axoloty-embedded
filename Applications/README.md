# Applications

What a firmware does: its agent behavior, object model usage, and IO endpoints.

An application is platform-neutral and transport-neutral. It names no board,
SDK, or broker. Board integration belongs in `Platforms/`, carrier code in
`Transports/`, and a concrete selection in `Profiles/`.
