// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Declares an Embedded Swift application with a generated C entry point.
@attached(extension, conformances: EmbeddedApplicationDefinition)
@attached(peer, names: named(axoloty_application_main), named(__axoloty_application_state))
public macro EmbeddedApplication() = #externalMacro(
    module: "EmbeddedApplicationMacroImplementation",
    type: "EmbeddedApplicationMacro"
)
