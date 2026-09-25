import { createMDX } from "fumadocs-mdx/next";

const withMDX = createMDX();

// Empty on Vercel. Set it to serve the static export from a sub-path.
const basePath = process.env.DOCS_BASE_PATH ?? "";

/** @type {import('next').NextConfig} */
const config = {
  output: "export",
  reactStrictMode: true,
  basePath,
  env: {
    NEXT_PUBLIC_BASE_PATH: basePath,
  },
};

export default withMDX(config);
