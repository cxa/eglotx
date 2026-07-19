import pluginVue from "eslint-plugin-vue";
import tseslint from "typescript-eslint";

export default [
  ...tseslint.configs.recommended,
  ...pluginVue.configs["flat/essential"],
  {
    files: ["**/*.vue"],
    languageOptions: {
      parserOptions: { parser: tseslint.parser },
    },
    rules: {
      "@typescript-eslint/no-unused-vars": "error",
    },
  },
];
