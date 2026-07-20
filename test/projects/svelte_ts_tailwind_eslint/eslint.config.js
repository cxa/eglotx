import pluginSvelte from "eslint-plugin-svelte";
import tseslint from "typescript-eslint";

export default [
  ...tseslint.configs.recommended,
  ...pluginSvelte.configs.recommended,
  {
    files: ["**/*.svelte"],
    languageOptions: {
      parserOptions: {
        parser: tseslint.parser,
        extraFileExtensions: [".svelte"],
      },
    },
    rules: {
      "@typescript-eslint/no-unused-vars": "error",
    },
  },
];
