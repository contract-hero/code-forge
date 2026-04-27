const ANSI_PATTERN = /\x1b\[[0-9;]*[a-zA-Z]/g;

export function stripAnsi(input: string): string {
  if (typeof input !== "string") {
    throw new TypeError("stripAnsi expects a string");
  }
  if (input.length === 0) return input;
  return removeSequences(input);
}

function removeSequences(s: string): string {
  let out = "";
  let i = 0;
  while (i < s.length) {
    const m = ANSI_PATTERN.exec(s.slice(i));
    if (m && m.index === 0) {
      i += m[0].length;
    } else {
      out += s[i];
      i++;
    }
  }
  return out;
}
