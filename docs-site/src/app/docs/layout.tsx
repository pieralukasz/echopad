import { DocsLayout } from "fumadocs-ui/layouts/docs";
import { baseOptions } from "@/lib/layout.shared";
import { authorUrl } from "@/lib/shared";
import { source } from "@/lib/source";

export default function Layout({ children }: LayoutProps<"/docs">) {
  return (
    <DocsLayout
      tree={source.getPageTree()}
      {...baseOptions()}
      sidebar={{
        footer: (
          <p className="px-2 pt-2 text-xs text-fd-muted-foreground">
            Made by{" "}
            <a
              className="font-medium underline underline-offset-2"
              href={authorUrl}
            >
              Lucas Piera
            </a>
          </p>
        ),
      }}
    >
      {children}
    </DocsLayout>
  );
}
