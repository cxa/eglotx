import tsParser from "@typescript-eslint/parser";
import astro from "eslint-plugin-astro";

export default [
  ...astro.configs.recommended,
  {
    files: ["**/*.astro"],
    languageOptions: {
      parserOptions: { parser: tsParser },
    },
    rules: { "no-unused-vars": "error" },
  },
];
