export function stripAnsi(input: string): string {
  if (!input) return input;
  return input.replace(/\x1b\[[0-9;]*m/g, "");
}
