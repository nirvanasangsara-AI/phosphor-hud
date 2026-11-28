/** Clock parsing for reset announcements. Offsets are hours ahead of UTC. */

export function zoneOffsetHours(zone, year, month, day, hour) {
  const name = String(zone || "UTC").toUpperCase();
  if (name === "KST") return 9;
  if (name === "UTC" || name === "GMT") return 0;
  if (name === "PDT") return -7;
  if (name === "PST") return -8;
  if (name === "EDT") return -4;
  if (name === "EST") return -5;
  if (name === "PT") return usDaylight(year, month, day, hour) ? -7 : -8;
  if (name === "ET") return usDaylight(year, month, day, hour) ? -4 : -5;
  return 0;
}

/** US daylight time: 02:00 on the second Sunday of March through 02:00 on the first Sunday of November. */
export function usDaylight(year, month, day, hour) {
  if (month < 3 || month > 11) return false;
  if (month > 3 && month < 11) return true;
  const start = nthSunday(year, 3, 2);
  const end = nthSunday(year, 11, 1);
  if (month === 3) return day > start || (day === start && hour >= 2);
  return day < end || (day === end && hour < 2);
}

function nthSunday(year, month, n) {
  const first = new Date(Date.UTC(year, month - 1, 1));
  const weekday = first.getUTCDay();
  return 1 + ((7 - weekday) % 7) + (n - 1) * 7;
}

export function expectedReset(text, posted) {
  const match = String(text).match(/(\d{1,2})[\/\-.](\d{1,2})(?:[\/\-.](\d{2,4}))?[^\d]{0,12}(\d{1,2}):(\d{2})\s*(KST|UTC|GMT|PT|PST|PDT|ET|EST|EDT)?/i);
  if (!match) return null;
  let month = Number(match[1]);
  let day = Number(match[2]);
  let year = match[3] ? Number(match[3]) : posted.getUTCFullYear();
  if (month > 12 && day <= 12) {
    const swap = month;
    month = day;
    day = swap;
  }
  if (year < 100) year += 2000;
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const offset = zoneOffsetHours(match[6] || "UTC", year, month, day, hour);
  const utc = Date.UTC(year, month - 1, day, hour - offset, minute);
  if (Number.isNaN(utc)) return null;
  return new Date(utc).toISOString();
}
