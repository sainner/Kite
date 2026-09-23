// 只开 TypeScript 查不出来的两条：没接住的 Promise（错误被悄悄吞掉、时序乱掉），把异步函数交给只接同步回调的地方
import tseslint from 'typescript-eslint';

export default [{
  files: ['**/*.ts'],
  languageOptions: {
    parser: tseslint.parser,
    parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
  },
  plugins: { '@typescript-eslint': tseslint.plugin },
  rules: {
    '@typescript-eslint/no-floating-promises': 'error',
    '@typescript-eslint/no-misused-promises': 'error',
  },
}];
