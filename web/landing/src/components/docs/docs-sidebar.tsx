"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

// The docs navigation tree, rendered from fumadocs' page tree (built from the
// meta.json ordering under content/docs). We type the tree structurally rather
// than importing fumadocs' internal PageTree namespace, which isn't exported on
// a stable public path — the shape below is the data contract we depend on.

type TreeItem = {
  type: "page";
  name: ReactNode;
  url: string;
  $id?: string;
};
type TreeSeparator = { type: "separator"; name?: ReactNode; $id?: string };
type TreeFolder = {
  type: "folder";
  name: ReactNode;
  index?: TreeItem;
  children: TreeNode[];
  $id?: string;
};
export type TreeNode = TreeItem | TreeSeparator | TreeFolder;
export type TreeRoot = { children: TreeNode[] };

function NodeLink({ node }: { node: TreeItem }) {
  const pathname = usePathname();
  const active = pathname === node.url;
  return (
    <Link
      href={node.url}
      aria-current={active ? "page" : undefined}
      className={cn(
        "block rounded-lg px-3 py-1.5 text-[13.5px] leading-snug transition-colors",
        active
          ? "bg-secondary font-medium text-foreground"
          : "text-muted-foreground hover:text-foreground",
      )}
    >
      {node.name}
    </Link>
  );
}

function SidebarNodes({ nodes }: { nodes: TreeNode[] }) {
  return (
    <ul className="space-y-0.5">
      {nodes.map((node, i) => {
        if (node.type === "separator") {
          return (
            <li
              key={node.$id ?? `sep-${i}`}
              className="px-3 pb-1.5 pt-6 text-[11px] font-semibold uppercase tracking-[0.08em] text-muted-foreground/70 first:pt-0"
            >
              {node.name}
            </li>
          );
        }
        if (node.type === "folder") {
          return (
            <li key={node.$id ?? `folder-${i}`} className="pt-4 first:pt-0">
              {node.index ? (
                <NodeLink node={node.index} />
              ) : (
                <div className="px-3 py-1.5 text-[13.5px] font-medium text-foreground">
                  {node.name}
                </div>
              )}
              <div className="mt-0.5 ml-3 border-l border-border pl-2">
                <SidebarNodes nodes={node.children} />
              </div>
            </li>
          );
        }
        return (
          <li key={node.$id ?? node.url}>
            <NodeLink node={node} />
          </li>
        );
      })}
    </ul>
  );
}

export function DocsSidebar({ tree }: { tree: TreeRoot }) {
  return (
    <nav aria-label="Docs" className="w-full">
      <SidebarNodes nodes={tree.children} />
    </nav>
  );
}
