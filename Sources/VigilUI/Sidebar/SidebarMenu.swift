//
//  SidebarMenu.swift
//  VigilUI
//
//  The right-click menu on a sidebar row, described as data so the panel still fetches nothing.
//  macOS-only. See docs/UX.md §4.3 (row actions) and the class doc on ``VSidebarView``.
//

#if os(macOS)

import Foundation
import SwiftUI

// MARK: - VSidebarMenuItem

/// One entry in a sidebar row's context menu.
///
/// **Why a value and not a `@ViewBuilder`.** ``VSidebarView``'s governing rule is that everything
/// arrives and nothing is fetched — the panel takes built values and reports back through closures,
/// which is what lets it render from a literal in a preview. A menu supplied as a view builder would
/// also mean a second generic parameter on `VSidebarView`, which is already generic over its
/// thumbnail; every call site and every preview would then have to spell both.
///
/// The titles are resolved `String`s rather than `LocalizedStringKey`s on purpose. Most of them
/// carry a user's own camera or group name — *Add to "Back Yard"* — and a key would send that name
/// to the localisation table as a lookup and render the raw text when it missed.
package struct VSidebarMenuItem: Identifiable {

    // MARK: - Role

    /// How the item is drawn and, for a destructive one, warned about.
    package enum Role: Sendable, Hashable {

        /// An ordinary action.
        case normal

        /// Something that removes or deletes. Drawn in the system's destructive style.
        case destructive
    }

    // MARK: - Stored Properties

    /// Stable identity within its menu. Separators need one too — two separators with the same id
    /// would make `ForEach` collapse them into one.
    package let id: String

    /// The label, already resolved and already localised by whoever built it.
    package let title: String

    /// A leading glyph, or `nil` for a text-only row.
    package let symbol: VTheme.Symbol?

    /// Ordinary or destructive.
    package let role: Role

    /// Whether it can be chosen. A disabled item stays visible, so the menu's shape does not change
    /// between two cameras and a user who learnt where an action sits still finds it there.
    package let isEnabled: Bool

    /// Draws a checkmark, for an item that reports a state — which group a camera is in, say.
    package let isOn: Bool

    /// A submenu. Empty for a leaf.
    package let children: [VSidebarMenuItem]

    /// What choosing it does. `nil` **and** no children makes the item a separator, and the title
    /// is then ignored.
    package let action: (() -> Void)?

    // MARK: - Initialisation

    /// Creates one entry.
    ///
    /// - Parameters:
    ///   - id: unique within this menu.
    ///   - title: resolved label text.
    ///   - symbol: leading glyph, or `nil`.
    ///   - role: ordinary or destructive.
    ///   - isEnabled: whether it can be chosen.
    ///   - isOn: whether it carries a checkmark.
    ///   - children: submenu entries, or empty for a leaf.
    ///   - action: performed on choose.
    package init(id: String,
                 title: String,
                 symbol: VTheme.Symbol? = nil,
                 role: Role = .normal,
                 isEnabled: Bool = true,
                 isOn: Bool = false,
                 children: [VSidebarMenuItem] = [],
                 action: (() -> Void)? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.role = role
        self.isEnabled = isEnabled
        self.isOn = isOn
        self.children = children
        self.action = action
    }

    /// A parent with a submenu under it.
    ///
    /// Disabled automatically when it has nothing in it: a submenu that opens onto an empty sheet is
    /// the least informative thing a menu can do.
    package static func submenu(id: String,
                                title: String,
                                symbol: VTheme.Symbol? = nil,
                                _ children: [VSidebarMenuItem]) -> VSidebarMenuItem {
        VSidebarMenuItem(id: id,
                         title: title,
                         symbol: symbol,
                         isEnabled: !children.isEmpty,
                         children: children)
    }

    /// A dividing rule.
    package static func separator(id: String) -> VSidebarMenuItem {
        VSidebarMenuItem(id: id, title: "")
    }

    /// Whether this entry is a separator rather than something choosable.
    package var isSeparator: Bool {
        action == nil && children.isEmpty
    }
}

// MARK: - VSidebarMenuItems

/// Renders a menu described by ``VSidebarMenuItem``s, submenus included.
///
/// Recursive, because the menus the sidebar needs are two deep — *Add to Group ▸ Back Yard* — and
/// flattening that into one list would put every group name at the top level of a menu that also
/// holds Rename and Delete.
@MainActor
package struct VSidebarMenuItems: View {

    /// The entries to draw, in order.
    package let items: [VSidebarMenuItem]

    /// Creates the menu body.
    package init(items: [VSidebarMenuItem]) {
        self.items = items
    }

    package var body: some View {
        ForEach(items) { item in
            entry(item)
        }
    }

    // MARK: - Private Helpers

    @ViewBuilder
    private func entry(_ item: VSidebarMenuItem) -> some View {
        if !item.children.isEmpty {
            Menu {
                VSidebarMenuItems(items: item.children)
            } label: {
                label(item)
            }
            .disabled(!item.isEnabled)
        } else if item.isSeparator {
            Divider()
        } else if item.isOn {
            // A `Toggle` rather than a `Button` with a drawn tick: on macOS this is what produces
            // the menu's own checkmark column, so a checked item lines up with every other app's.
            // The binding's setter is the action — a menu item is chosen, never "set to false".
            Toggle(isOn: Binding(get: { true }, set: { _ in item.action?() })) {
                label(item)
            }
            .disabled(!item.isEnabled)
        } else {
            Button(role: item.role == .destructive ? .destructive : nil,
                   action: { item.action?() }) {
                label(item)
            }
            .disabled(!item.isEnabled)
        }
    }

    /// The glyph and the text. `Text(verbatim:)` throughout — these carry user data.
    @ViewBuilder
    private func label(_ item: VSidebarMenuItem) -> some View {
        if let symbol = item.symbol {
            Label {
                Text(verbatim: item.title)
            } icon: {
                symbol.image()
            }
        } else {
            Text(verbatim: item.title)
        }
    }
}

// MARK: - VSidebarRowMenu

/// Attaches a context menu to a row, or leaves it alone when there is nothing to show.
///
/// A modifier rather than an inline `.contextMenu`, because the "nothing to show" branch has to
/// return the row **without** the modifier applied. `.contextMenu { EmptyView() }` still claims the
/// right-click and opens an empty grey rectangle, which reads as the app having tried and failed —
/// worse than letting the system do whatever it would have done.
@MainActor
package struct VSidebarRowMenu: ViewModifier {

    /// The entries, or empty for no menu at all.
    package let items: [VSidebarMenuItem]

    /// Creates the modifier.
    package init(items: [VSidebarMenuItem]) {
        self.items = items
    }

    /// `@ViewBuilder` is spelled out rather than relied on. `ViewModifier` does declare its
    /// requirement with the attribute and a witness inherits it, but the two branches return
    /// different types and a silent inference change here would be a confusing compile error in a
    /// file that had not been touched.
    @ViewBuilder
    package func body(content: Content) -> some View {
        if items.isEmpty {
            content
        } else {
            content.contextMenu { VSidebarMenuItems(items: items) }
        }
    }
}

#endif  // os(macOS)
