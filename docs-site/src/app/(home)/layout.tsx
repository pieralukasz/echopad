import { Literata } from "next/font/google";
import "./home.css";

const literata = Literata({
  subsets: ["latin", "latin-ext"],
  weight: ["400", "500", "600"],
  style: ["normal", "italic"],
  variable: "--font-ep",
});

/** The home page has its own bar and footer; /docs keeps the Fumadocs layout. */
export default function Layout({ children }: LayoutProps<"/">) {
  return <div className={`ep ${literata.variable}`}>{children}</div>;
}
