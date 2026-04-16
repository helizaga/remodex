const js = require("@eslint/js");
const globals = require("globals");

module.exports = [
  {
    ignores: ["**/node_modules/**", "CodexMobile/CodexMobile/Resources/Mermaid/**"],
  },
  js.configs.recommended,
  {
    files: ["phodex-bridge/**/*.js", "relay/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "commonjs",
      globals: {
        ...globals.node,
      },
    },
    rules: {
      "no-console": "off",
      "no-empty": "off",
      "no-unused-vars": [
        "error",
        {
          varsIgnorePattern: "^_",
          argsIgnorePattern: "^_",
          caughtErrors: "none",
        },
      ],
    },
  },
];
