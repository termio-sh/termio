import keybindings from "@/data/keybindings.json";

// Renders one category of the app's shortcut catalog. The data is generated from
// Sources/termio/Keybindings/KeyCommand.swift (pnpm keybindings:sync), so the docs
// can't claim a binding the app doesn't ship — which they did for two releases.
//
// Command names stay in English: they're the menu titles, and the table is a map
// of the app's own menus.
export function Keybindings({
  category,
  unboundLabel = "Unbound",
}: {
  category: string;
  unboundLabel?: string;
}) {
  const group = keybindings.categories.find((c) => c.title === category);
  if (!group) {
    throw new Error(
      `Keybindings: no "${category}" category in keybindings.json — categories are ${keybindings.categories
        .map((c) => c.title)
        .join(", ")}`,
    );
  }

  return (
    <table>
      <thead>
        <tr>
          <th>Command</th>
          <th>Shortcut</th>
        </tr>
      </thead>
      <tbody>
        {group.commands.map((command) => (
          <tr key={command.id}>
            <td>{command.title}</td>
            <td>
              {command.shortcut ? (
                <code>{command.shortcut}</code>
              ) : (
                <span className="text-muted-foreground">{unboundLabel}</span>
              )}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
