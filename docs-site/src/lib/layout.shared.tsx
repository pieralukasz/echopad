import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared";
import { appName, asset, repoUrl } from "./shared";

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: (
        <span className="inline-flex items-center gap-2 font-semibold">
          {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
          <img
            src={asset("/icon-256.png")}
            alt=""
            width={24}
            height={24}
            className="rounded-md"
          />
          {appName}
        </span>
      ),
    },
    githubUrl: repoUrl,
    links: [
      { text: "Docs", url: "/docs" },
      { text: "Install", url: "/docs/installation" },
      { text: "Packages", url: "/docs/packages" },
    ],
  };
}
