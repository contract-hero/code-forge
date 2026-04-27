export function stripAnsi(input: string): string {
  return input.replace("\x1b[", "");
}
