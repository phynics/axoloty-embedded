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

        guard validateShape(declaration, attribute: node, context: context) else {
            return []
        }

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
                    let result = \(appName).run(capabilities, state: &__axoloty_application_state)
                    return EmbeddedApplicationEntryAdapter.status(for: result)
                }
                """)
        ]
    }

    private static func supportedNamespaceName(_ declaration: some DeclSyntaxProtocol) -> String? {
        if let enumeration = declaration.as(EnumDeclSyntax.self) { return enumeration.name.text }
        if let structure = declaration.as(StructDeclSyntax.self) { return structure.name.text }
        return nil
    }

    private static func validateShape(
        _ declaration: some DeclSyntaxProtocol,
        attribute: AttributeSyntax,
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
            let isStatic = function.modifiers.contains { $0.name.text == "static" }
            if !isStatic {
                diagnose("application run must be static", at: attribute, in: context)
                valid = false
            }
            if function.signature.effectSpecifiers?.asyncSpecifier != nil {
                diagnose("application run must be synchronous", at: attribute, in: context)
                valid = false
            }
        }
        return valid
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
        guard supportedNamespaceName(declaration) != nil else {
            return []
        }
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
