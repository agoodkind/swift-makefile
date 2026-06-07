//
//  TopLevelTypeDeclaration.swift
//  SwiftCheckCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-30.
//  Copyright © 2026, all rights reserved.
//

import SwiftSyntax

// MARK: - TopLevelTypeDeclaration

struct TopLevelTypeDeclaration {
  let firstToken: TokenSyntax
  let keyword: TokenSyntax
  let name: String
}

func topLevelTypeDeclaration(_ item: CodeBlockItemSyntax) -> TopLevelTypeDeclaration? {
  let declaration = item.item
  let keyword: TokenSyntax
  let name: String
  if let structDecl = declaration.as(StructDeclSyntax.self) {
    keyword = structDecl.structKeyword
    name = structDecl.name.text
  } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
    keyword = classDecl.classKeyword
    name = classDecl.name.text
  } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
    keyword = enumDecl.enumKeyword
    name = enumDecl.name.text
  } else if let actorDecl = declaration.as(ActorDeclSyntax.self) {
    keyword = actorDecl.actorKeyword
    name = actorDecl.name.text
  } else if let protocolDecl = declaration.as(ProtocolDeclSyntax.self) {
    keyword = protocolDecl.protocolKeyword
    name = protocolDecl.name.text
  } else if let extensionDecl = declaration.as(ExtensionDeclSyntax.self) {
    keyword = extensionDecl.extensionKeyword
    name = extensionDecl.extendedType.trimmedDescription
  } else {
    return nil
  }
  guard let firstToken = Syntax(declaration).firstToken(viewMode: .sourceAccurate) else {
    return nil
  }
  return TopLevelTypeDeclaration(firstToken: firstToken, keyword: keyword, name: name)
}

private let titledMarkPrefix = "// MARK: -"

func leadingTriviaHasTitledMark(_ token: TokenSyntax) -> Bool {
  for piece in token.leadingTrivia {
    let commentText: String
    switch piece {
    case .lineComment(let text):
      commentText = text
    case .blockComment(let text):
      commentText = text
    default:
      continue
    }
    let trimmed = commentText.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(titledMarkPrefix) else {
      continue
    }
    let title = trimmed.dropFirst(titledMarkPrefix.count).trimmingCharacters(in: .whitespaces)
    if !title.isEmpty {
      return true
    }
  }
  return false
}

/// A file with fewer than this many top-level type or extension declarations is
/// exempt: a lone type does not need a section divider to orient the reader.
private let minimumTypeDeclarationsForSections = 2

func missingSectionMarkViolations(
  path: String, tree: SourceFileSyntax, converter: SourceLocationConverter
) -> [Violation] {
  let typeDeclarations = tree.statements.compactMap(topLevelTypeDeclaration)
  guard typeDeclarations.count >= minimumTypeDeclarationsForSections else {
    return []
  }

  var violations: [Violation] = []
  for declaration in typeDeclarations.dropFirst()
  where !leadingTriviaHasTitledMark(declaration.firstToken) {
    let value = location(
      for: declaration.keyword.positionAfterSkippingLeadingTrivia, converter: converter)
    violations.append(
      Violation(
        path: path,
        line: value.line,
        column: value.column,
        rule: .missingSectionMark,
        detail:
          "add a titled `// MARK: - \(declaration.name)` divider before this top-level "
          + "declaration"
      )
    )
  }
  return violations
}
