const KIB = 1024;
const MIB = KIB ** 2;
const GIB = KIB ** 3;
const SVG_NS = "http://www.w3.org/2000/svg";

export function h(tag, props, ...kids) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(props ?? {})) {
    if (value === undefined || value === null || value === false) continue;
    if (name === "class") node.className = value;
    else if (name === "text") node.textContent = value;
    else if (name === "data") Object.entries(value).forEach(([k, v]) => (node.dataset[k] = v));
    else if (name === "style") Object.entries(value).forEach(([k, v]) => node.style.setProperty(k, v));
    else if (name.startsWith("on")) node.addEventListener(name.slice(2).toLowerCase(), value);
    else node.setAttribute(name, value);
  }
  for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) node.append(kid);
  return node;
}

export function glyph(name, className) {
  const svg = document.createElementNS(SVG_NS, "svg");
  if (className) svg.setAttribute("class", className);
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(SVG_NS, "use");
  use.setAttribute("href", `#i-${name}`);
  svg.append(use);
  return svg;
}

export function number(lang, value, digits) {
  return new Intl.NumberFormat(lang, { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(value);
}

export function size(lang, bytes) {
  if (bytes >= GIB) return `${number(lang, bytes / GIB, bytes >= 10 * GIB ? 0 : 1)} GB`;
  if (bytes >= MIB) return `${number(lang, bytes / MIB, 0)} MB`;
  if (bytes >= KIB) return `${number(lang, bytes / KIB, 0)} KB`;
  return `${number(lang, bytes, 0)} B`;
}

export function heroSize(bytes) {
  if (bytes < MIB) return { value: bytes / MIB, unit: "MB", digits: 0 };
  if (bytes >= GIB) {
    const raw = bytes / GIB;
    return { value: raw, unit: "GB", digits: raw >= 10 ? 1 : 2 };
  }
  return { value: bytes / MIB, unit: "MB", digits: 0 };
}

export function clockLabel(lang, ms) {
  return ms < 1000 ? `${number(lang, ms, 0)}ms` : `${number(lang, ms / 1000, 1)}s`;
}

export function countUp(node, to, format, duration = 1500) {
  const REDUCED = matchMedia("(prefers-reduced-motion: reduce)");
  if (REDUCED.matches) {
    node.textContent = format(to);
    return;
  }
  const start = performance.now();
  const frame = (now) => {
    const progress = Math.min(1, (now - start) / duration);
    node.textContent = format(to * (1 - (1 - progress) ** 4));
    if (progress < 1) requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}

export function findingKey(finding) {
  return `${finding.ruleId} :: ${finding.path}`;
}
