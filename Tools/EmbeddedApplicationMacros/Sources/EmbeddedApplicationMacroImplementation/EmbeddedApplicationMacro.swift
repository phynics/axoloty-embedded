// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Errors raised while ``EmbeddedApplicationMacro`` builds peer declarations.
public enum EmbeddedApplicationMacroError: Error {
    /// The generated extension declaration string could not be parsed.
    case invalidExtensionSyntax
}

private struct EmbeddedApplicationDiagnostic: DiagnosticMessage {
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "EmbeddedApplication", id: "invalid-declaration") }
    var severity: DiagnosticSeverity { .error }
}

public struct EmbeddedApplicationMacro: PeerMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws(EmbeddedApplicationMacroError) -> [DeclSyntax] {
        guard let appName = supportedNamespaceName(declaration) else {
            diagnose("@EmbeddedApplication requires a namespace enum or struct", at: node, in: context)
            return []
        }

        guard let traceEnabled = traceArgument(node, context: context),
              validateShape(declaration, attribute: node, traceEnabled: traceEnabled, context: context) else {
            return []
        }

        let traceEntry = traceEnabled ? """
                    EmbeddedApplicationEntryAdapter.requireHeapTraceInitialization(
                        EmbeddedApplicationRequirements.self
                    )
                    guard EmbeddedApplicationEntryAdapter.hasHeapTraceRequirements(
                        EmbeddedApplicationRequirements.current
                    ) else {
                        return AXOLOTY_APPLICATION_STATUS_TRACE_REQUIREMENTS_MISMATCH
                    }
                    do {
                        try capabilities.platform.beginHeapTrace()
                    } catch let error {
                        return EmbeddedApplicationEntryAdapter.traceStatus(for: error)
                    }
                    \(appName).initializeStaticState()
                    return withUnsafeMutablePointer(to: &__axoloty_application_state) { statePointer in
                        let allocationCount: UInt32
                        do {
                            allocationCount = try capabilities.platform.endHeapTrace()
                        } catch let error as EmbeddedHeapTraceError {
                            return EmbeddedApplicationEntryAdapter.traceStatus(for: error)
                        } catch {
                            return EmbeddedApplicationEntryAdapter.invalidABIStatus
                        }
                        guard allocationCount == 0 else {
                            return EmbeddedApplicationEntryAdapter.traceAllocationsObservedStatus
                        }
                        let result = \(appName).run(capabilities, state: &statePointer.pointee)
                        return EmbeddedApplicationEntryAdapter.status(for: result)
                    }
            """ : """
                    let result = \(appName).run(capabilities, state: &__axoloty_application_state)
                    return EmbeddedApplicationEntryAdapter.status(for: result)
            """

        return [
            DeclSyntax(stringLiteral:
                "nonisolated(unsafe) private var __axoloty_application_state: \(appName).State = .init()"),
            DeclSyntax(stringLiteral: """
                @_cdecl("axoloty_application_main")
                func axoloty_application_main(
                    _ platform: UnsafePointer<axoloty_platform_v1>?,
                    _ carrier: UnsafePointer<axoloty_carrier_v1>?
                ) -> Int32 {
                    let stateStride = UInt64(MemoryLayout<\(appName).State>.stride)
                    let stateBudget = UInt64(EmbeddedApplicationRequirements.current.applicationStateBytes)
                    guard stateStride <= stateBudget else {
                        return EmbeddedApplicationEntryAdapter.stateBudgetExceededStatus
                    }
                    guard let capabilities = EmbeddedApplicationEntryAdapter.capabilities(
                        validatingPlatform: platform, carrier: carrier,
                        requirements: EmbeddedApplicationRequirements.current
                    ) else {
                        return EmbeddedApplicationEntryAdapter.invalidABIStatus
                    }
                    guard EmbeddedApplicationEntryAdapter.claimEntry() else {
                        return EmbeddedApplicationEntryAdapter.alreadyEnteredStatus
                    }
                \(traceEntry)
                }
                """)
        ]
    }

    private static func traceArgument(
        _ node: AttributeSyntax,
        context: some MacroExpansionContext
    ) -> Bool? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return false }
        var found = false
        var enabled = false
        for argument in arguments {
            guard argument.label?.text == "traceFirstInitialization" else {
                diagnose("@EmbeddedApplication supports only traceFirstInitialization: Bool", at: argument, in: context)
                return nil
            }
            guard !found else {
                diagnose("@EmbeddedApplication argument traceFirstInitialization may appear only once", at: argument, in: context)
                return nil
            }
            found = true
            guard let literal = argument.expression.as(BooleanLiteralExprSyntax.self) else {
                diagnose("traceFirstInitialization must be a literal true or false", at: argument.expression, in: context)
                return nil
            }
            enabled = literal.literal.text == "true"
        }
        return enabled
    }

    private static func supportedNamespaceName(_ declaration: some DeclSyntaxProtocol) -> String? {
        if let enumeration = declaration.as(EnumDeclSyntax.self) { return enumeration.name.text }
        if let structure = declaration.as(StructDeclSyntax.self) { return structure.name.text }
        return nil
    }

    private static func validateShape(
        _ declaration: some DeclSyntaxProtocol,
        attribute: AttributeSyntax,
        traceEnabled: Bool,
        context: some MacroExpansionContext
    ) -> Bool {
        guard let members = namespaceMembers(declaration) else { return false }
        var valid = true

        let stateCount = members.filter(isStateDeclaration).count
        if stateCount == 0 {
            diagnose("application must declare State (a nested type or typealias)", at: attribute, in: context)
            valid = false
        } else if stateCount > 1 {
            diagnose("application must declare exactly one State", at: attribute, in: context)
            valid = false
        }

        let runFunctions = members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
            .filter { $0.name.text == "run" }
        if runFunctions.isEmpty {
            diagnose("application must declare static run", at: attribute, in: context)
            return false
        }
        if runFunctions.count > 1 {
            diagnose("application must declare exactly one run function", at: attribute, in: context)
            valid = false
        }
        for function in runFunctions {
            if !function.modifiers.contains(where: { $0.name.text == "static" }) {
                diagnose("application run must be static", at: attribute, in: context)
                valid = false
            }
            if function.signature.effectSpecifiers?.asyncSpecifier != nil {
                diagnose("application run must be synchronous", at: attribute, in: context)
                valid = false
            }
        }

        if traceEnabled {
            let hooks = members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
                .filter { $0.name.text == "initializeStaticState" }
            if hooks.count != 1 {
                diagnose("traceFirstInitialization requires exactly one static initializeStaticState() hook", at: attribute, in: context)
                valid = false
            }
            for hook in hooks where !validInitializationHook(hook) {
                diagnose("initializeStaticState must be static, synchronous, nonthrowing, parameterless, and return Void", at: attribute, in: context)
                valid = false
            }
        }
        return valid
    }

    private static func validInitializationHook(_ function: FunctionDeclSyntax) -> Bool {
        let isStatic = function.modifiers.contains { $0.name.text == "static" }
        let hasNoParameters = function.signature.parameterClause.parameters.isEmpty
        let effect = function.signature.effectSpecifiers
        let isSynchronous = effect?.asyncSpecifier == nil
        let isNonthrowing = effect?.throwsClause == nil
        let returnType = function.signature.returnClause?.type.trimmedDescription ?? "Void"
        return isStatic && hasNoParameters && isSynchronous && isNonthrowing && (returnType == "Void" || returnType == "()")
    }

    private static func namespaceMembers(_ declaration: some DeclSyntaxProtocol) -> MemberBlockItemListSyntax? {
        if let enumeration = declaration.as(EnumDeclSyntax.self) { return enumeration.memberBlock.members }
        if let structure = declaration.as(StructDeclSyntax.self) { return structure.memberBlock.members }
        return nil
    }

    private static func isStateDeclaration(_ member: MemberBlockItemSyntax) -> Bool {
        if member.decl.as(TypeAliasDeclSyntax.self)?.name.text == "State" { return true }
        if member.decl.as(StructDeclSyntax.self)?.name.text == "State" { return true }
        return false
    }

    private static func diagnose(
        _ message: String,
        at node: some SyntaxProtocol,
        in context: some MacroExpansionContext
    ) {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: EmbeddedApplicationDiagnostic(message: message)
        ))
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws(EmbeddedApplicationMacroError) -> [ExtensionDeclSyntax] {
        guard supportedNamespaceName(declaration) != nil else { return [] }
        do {
            return [try ExtensionDeclSyntax("extension \(type): EmbeddedApplicationDefinition {}")]
        } catch {
            throw .invalidExtensionSyntax
        }
    }
}

@main
struct EmbeddedApplicationMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [EmbeddedApplicationMacro.self]
}
