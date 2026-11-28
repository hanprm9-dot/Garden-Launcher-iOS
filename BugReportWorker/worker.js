// Garden Launcher iOS — Bug Report Bridge v2.0 (Cloudflare Worker -> Discord Webhook)
// Sends rich Discord Embed + ONE consolidated BugReport-#GL-XXXXXX.zip bundle containing:
//   - 00-BAO-LOI-TONG-HOP.md   (full human-readable report: description, device, iOS, RAM, mods, diagnostics)
//   - 01-report-metadata.json  (machine-readable JSON of all report fields & file inventory)
//   - logs/*                   (all sanitized log files extracted losslessly from ErrorLogs.zip)
//   - media/*                  (up to 3 attached images/videos: JPG/PNG/WEBP/GIF/MP4/MOV)
//
// Required Secrets in Worker Settings -> Variables & Secrets:
//   DISCORD_WEBHOOK_URL = https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN
//   REPORT_CLIENT_KEY   = your-secret-client-key (must match SDV_BUG_REPORT_CLIENT_KEY at build time; fails closed if unset!)

const MAX_ZIP_BYTES = 7.5 * 1024 * 1024;   // 7.5 MB cap for incoming ErrorLogs.zip
const MAX_MEDIA_BYTES = 7.5 * 1024 * 1024; // 7.5 MB per image/video
const MAX_TOTAL_BYTES = 9.0 * 1024 * 1024; // 9.0 MB combined (safe margin under Discord 10 MB limit)
const MIN_COOLDOWN_MS = 45 * 1000;         // 45s minimum between reports from same IP/device
const WINDOW_MS = 15 * 60 * 1000;          // 15-minute rolling window
const MAX_PER_WINDOW = 5;                  // Max 5 reports per 15 min per IP

const rateMap = new Map();
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: false });

// Precomputed IEEE 802.3 CRC-32 table
const CRC32_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let j = 0; j < 8; j++) {
      c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    t[i] = c >>> 0;
  }
  return t;
})();

function crc32(bytes) {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    c = CRC32_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function dosDateTime(date) {
  // Store timestamps in Vietnam time (UTC+7) for intuitive viewing on Windows/iOS
  const vn = new Date(date.getTime() + 7 * 3600 * 1000);
  const year = Math.max(1980, Math.min(2107, vn.getUTCFullYear()));
  const month = vn.getUTCMonth() + 1;
  const day = vn.getUTCDate();
  const hours = vn.getUTCHours();
  const minutes = vn.getUTCMinutes();
  const seconds = Math.floor(vn.getUTCSeconds() / 2);
  return {
    dosTime: ((hours & 0x1f) << 11) | ((minutes & 0x3f) << 5) | (seconds & 0x1f),
    dosDate: (((year - 1980) & 0x7f) << 9) | ((month & 0x0f) << 5) | (day & 0x1f),
  };
}

function formatVnTimestamp(date) {
  const vn = new Date(date.getTime() + 7 * 3600 * 1000);
  const p = (n) => String(n).padStart(2, "0");
  return `${vn.getUTCFullYear()}-${p(vn.getUTCMonth() + 1)}-${p(vn.getUTCDate())} ${p(vn.getUTCHours())}:${p(vn.getUTCMinutes())}:${p(vn.getUTCSeconds())} (UTC+7)`;
}

function sanitizeZipRelPath(raw) {
  const norm = String(raw || "")
    .replace(/\\/g, "/")
    .split("/")
    .filter((seg) => seg && seg !== "." && seg !== "..")
    .join("/");
  return norm || "file.log";
}

// Losslessly parse entries from an existing ZIP (preserves original compression method, CRC32 & raw bytes)
function parseZipEntries(arrayBuf) {
  const bytes = new Uint8Array(arrayBuf);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.length < 22) throw new Error("ZIP too small");

  // Locate End of Central Directory (EOCD: 0x06054b50)
  const minPos = Math.max(0, bytes.length - 65557);
  let eocdPos = -1;
  for (let i = bytes.length - 22; i >= minPos; i--) {
    if (
      bytes[i] === 0x50 &&
      bytes[i + 1] === 0x4b &&
      bytes[i + 2] === 0x05 &&
      bytes[i + 3] === 0x06
    ) {
      const commentLen = view.getUint16(i + 20, true);
      if (i + 22 + commentLen === bytes.length) {
        eocdPos = i;
        break;
      }
    }
  }
  if (eocdPos < 0) throw new Error("EOCD not found");

  const entryCount = view.getUint16(eocdPos + 10, true);
  const cdSize = view.getUint32(eocdPos + 12, true);
  const cdOffset = view.getUint32(eocdPos + 16, true);
  if (cdOffset + cdSize > bytes.length) throw new Error("Central Directory out of range");

  const entries = [];
  let pos = cdOffset;
  for (let idx = 0; idx < entryCount; idx++) {
    if (pos + 46 > bytes.length || view.getUint32(pos, true) !== 0x02014b50) {
      throw new Error("Invalid Central Directory signature");
    }
    const flags = view.getUint16(pos + 8, true);
    const method = view.getUint16(pos + 10, true);
    const dosTime = view.getUint16(pos + 12, true);
    const dosDate = view.getUint16(pos + 14, true);
    const entryCrc = view.getUint32(pos + 16, true);
    const compSize = view.getUint32(pos + 20, true);
    const uncompSize = view.getUint32(pos + 24, true);
    const nameLen = view.getUint16(pos + 28, true);
    const extraLen = view.getUint16(pos + 30, true);
    const commentLen = view.getUint16(pos + 32, true);
    const lfhOffset = view.getUint32(pos + 42, true);

    const nameRaw = textDecoder.decode(bytes.subarray(pos + 46, pos + 46 + nameLen));
    pos += 46 + nameLen + extraLen + commentLen;

    if (nameRaw.endsWith("/")) continue; // skip directory placeholders
    if (lfhOffset + 30 > bytes.length || view.getUint32(lfhOffset, true) !== 0x04034b50) {
      throw new Error("Invalid Local File Header signature");
    }
    const lfhNameLen = view.getUint16(lfhOffset + 26, true);
    const lfhExtraLen = view.getUint16(lfhOffset + 28, true);
    const dataStart = lfhOffset + 30 + lfhNameLen + lfhExtraLen;
    if (dataStart + compSize > bytes.length) {
      throw new Error("Compressed data out of range");
    }

    entries.push({
      name: sanitizeZipRelPath(nameRaw),
      method,
      flags: (flags & ~0x0008) | 0x0800, // clear data-descriptor bit, set UTF-8 flag
      dosTime,
      dosDate,
      crc32: entryCrc,
      compSize,
      uncompSize,
      rawData: bytes.subarray(dataStart, dataStart + compSize),
    });
  }
  return entries;
}

// Build a clean standard PKZIP archive from prepared entries (STORE + preserved DEFLATE entries)
function buildZipArchive(entries) {
  const prepared = entries.map((e) => {
    const nameBytes = textEncoder.encode(e.name);
    return { ...e, nameBytes };
  });

  let localTotal = 0;
  let cdTotal = 0;
  for (const e of prepared) {
    localTotal += 30 + e.nameBytes.length + e.rawData.length;
    cdTotal += 46 + e.nameBytes.length;
  }

  const out = new Uint8Array(localTotal + cdTotal + 22);
  const view = new DataView(out.buffer);
  const offsets = new Uint32Array(prepared.length);

  // 1. Write Local File Headers + File Data
  let offset = 0;
  for (let i = 0; i < prepared.length; i++) {
    const e = prepared[i];
    offsets[i] = offset;
    view.setUint32(offset, 0x04034b50, true); // Local file header signature
    view.setUint16(offset + 4, 20, true);     // Version needed (2.0)
    view.setUint16(offset + 6, e.flags, true);
    view.setUint16(offset + 8, e.method, true);
    view.setUint16(offset + 10, e.dosTime, true);
    view.setUint16(offset + 12, e.dosDate, true);
    view.setUint32(offset + 14, e.crc32 >>> 0, true);
    view.setUint32(offset + 18, e.compSize >>> 0, true);
    view.setUint32(offset + 22, e.uncompSize >>> 0, true);
    view.setUint16(offset + 26, e.nameBytes.length, true);
    view.setUint16(offset + 28, 0, true);     // Extra field length
    out.set(e.nameBytes, offset + 30);
    offset += 30 + e.nameBytes.length;
    out.set(e.rawData, offset);
    offset += e.rawData.length;
  }

  // 2. Write Central Directory Headers
  const cdOffset = offset;
  for (let i = 0; i < prepared.length; i++) {
    const e = prepared[i];
    view.setUint32(offset, 0x02014b50, true); // Central directory signature
    view.setUint16(offset + 4, 20, true);     // Version made by
    view.setUint16(offset + 6, 20, true);     // Version needed
    view.setUint16(offset + 8, e.flags, true);
    view.setUint16(offset + 10, e.method, true);
    view.setUint16(offset + 12, e.dosTime, true);
    view.setUint16(offset + 14, e.dosDate, true);
    view.setUint32(offset + 16, e.crc32 >>> 0, true);
    view.setUint32(offset + 20, e.compSize >>> 0, true);
    view.setUint32(offset + 24, e.uncompSize >>> 0, true);
    view.setUint16(offset + 28, e.nameBytes.length, true);
    view.setUint16(offset + 30, 0, true);     // Extra length
    view.setUint16(offset + 32, 0, true);     // Comment length
    view.setUint16(offset + 34, 0, true);     // Disk number start
    view.setUint16(offset + 36, 0, true);     // Internal file attributes
    view.setUint32(offset + 38, 0, true);     // External file attributes
    view.setUint32(offset + 42, offsets[i], true);
    out.set(e.nameBytes, offset + 46);
    offset += 46 + e.nameBytes.length;
  }

  // 3. Write End of Central Directory (EOCD)
  view.setUint32(offset, 0x06054b50, true);
  view.setUint16(offset + 4, 0, true);
  view.setUint16(offset + 6, 0, true);
  view.setUint16(offset + 8, prepared.length, true);
  view.setUint16(offset + 10, prepared.length, true);
  view.setUint32(offset + 12, cdTotal, true);
  view.setUint32(offset + 16, cdOffset, true);
  view.setUint16(offset + 20, 0, true);

  return out;
}

function makeStoredEntry(name, rawData, dt) {
  const bytes = rawData instanceof Uint8Array ? rawData : new Uint8Array(rawData);
  return {
    name,
    method: 0,      // STORE
    flags: 0x0800,  // UTF-8 filename
    dosTime: dt.dosTime,
    dosDate: dt.dosDate,
    crc32: crc32(bytes),
    compSize: bytes.length,
    uncompSize: bytes.length,
    rawData: bytes,
  };
}

function checkRateLimit(key) {
  const now = Date.now();
  let rec = rateMap.get(key);
  if (!rec || now - rec.winStart > WINDOW_MS) {
    rec = { winStart: now, count: 0, lastAt: 0 };
  }
  if (rec.lastAt && now - rec.lastAt < MIN_COOLDOWN_MS) {
    const waitSec = Math.ceil((MIN_COOLDOWN_MS - (now - rec.lastAt)) / 1000);
    return { ok: false, retryAfter: waitSec, reason: `Vui lòng đợi ${waitSec} giây trước khi gửi báo lỗi tiếp theo.` };
  }
  if (rec.count >= MAX_PER_WINDOW) {
    return { ok: false, retryAfter: 300, reason: "Bạn đã gửi quá nhiều báo lỗi trong 15 phút qua. Vui lòng thử lại sau." };
  }
  rec.count += 1;
  rec.lastAt = now;
  rateMap.set(key, rec);
  if (rateMap.size > 5000) {
    for (const [k, v] of rateMap) {
      if (now - v.winStart > WINDOW_MS) rateMap.delete(k);
    }
  }
  return { ok: true };
}

function clampStr(val, maxLen, fallback = "") {
  const s = (typeof val === "string" ? val : "").trim();
  if (!s) return fallback;
  return s.length > maxLen ? s.slice(0, maxLen - 1) + "…" : s;
}

function categoryColor(cat) {
  const low = (cat || "").toLowerCase();
  if (low.includes("crash") || low.includes("văng")) return 0xe53935;
  if (low.includes("mod") || low.includes("xung")) return 0xfb8c00;
  if (low.includes("điều khiển") || low.includes("cảm ứng") || low.includes("tay cầm")) return 0x1e88e5;
  if (low.includes("đồ họa") || low.includes("shader")) return 0x8e24aa;
  if (low.includes("âm thanh")) return 0x00897b;
  return 0xfbc02d;
}

function makeReportId() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  let out = "GL-";
  for (let i = 0; i < bytes.length; i++) out += chars[bytes[i] % chars.length];
  return out;
}

function detectAllowedMedia(buf, origName) {
  const b = new Uint8Array(buf, 0, Math.min(16, buf.byteLength));
  if (b.length < 8) return null;
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) {
    return { ext: "jpg", mime: "image/jpeg" };
  }
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) {
    return { ext: "png", mime: "image/png" };
  }
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38) {
    return { ext: "gif", mime: "image/gif" };
  }
  if (
    b.length >= 12 &&
    b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
    b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50
  ) {
    return { ext: "webp", mime: "image/webp" };
  }
  if (b.length >= 12 && b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
    const brand = String.fromCharCode(b[8], b[9], b[10], b[11]);
    const low = (origName || "").toLowerCase();
    if (brand === "qt  ") {
      return { ext: "mov", mime: "video/quicktime" };
    }
    const allowedMp4Brands = ["isom", "iso2", "mp41", "mp42", "avc1", "M4V ", "3gp4", "3gp5", "mmp4", "MSNV"];
    if (allowedMp4Brands.includes(brand)) {
      const isMov = low.endsWith(".mov");
      return isMov ? { ext: "mov", mime: "video/quicktime" } : { ext: "mp4", mime: "video/mp4" };
    }
    return null;
  }
  return null;
}

function jsonResp(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function buildSummaryMarkdown(meta, logFileNames, mediaFileNames) {
  const lines = [
    `# 🐞 BÁO LỖI TỔNG HỢP GARDEN LAUNCHER — #${meta.reportId}`,
    ``,
    `- **Thời gian gửi:** ${meta.timestampVn} (\`${meta.timestampIso}\`)`,
    `- **Loại lỗi:** ${meta.category}`,
    `- **Phiên bản App:** Garden Launcher v${meta.appVersion}`,
    `- **Thiết bị:** ${meta.device} · iOS ${meta.iosVersion}`,
    `- **RAM:** ${meta.ramInfo}`,
    `- **Chế độ điều khiển:** ${meta.controlMode}`,
    `- **Liên hệ người gửi:** ${meta.contact}`,
    `- **Mã thiết bị ẩn danh:** \`${meta.deviceHash}\``,
    ``,
    `## 📝 Mô tả lỗi từ người dùng`,
    ``,
    meta.description,
    ``,
    `## 🧩 Danh sách Mod đang bật (${meta.modCount})`,
    ``,
    "```text",
    meta.modsSummary,
    "```",
  ];

  if (meta.issueSummary) {
    lines.push(
      ``,
      `## ⚠️ Cảnh báo Mod Garden phát hiện`,
      ``,
      "```text",
      meta.issueSummary,
      "```"
    );
  }

  lines.push(
    ``,
    `## 📦 Thành phần đính kèm trong gói tổng hợp này`,
    ``,
    `### 1. Nhật ký hệ thống & SMAPI (${logFileNames.length} tệp)`,
    ...(logFileNames.length
      ? logFileNames.map((n) => `- \`${n}\``)
      : [`- *(Không có tệp log đính kèm)*`]),
    ``,
    `### 2. Hình ảnh / Video minh họa (${mediaFileNames.length} tệp)`,
    ...(mediaFileNames.length
      ? mediaFileNames.map((n) => `- \`${n}\``)
      : [`- *(Không có ảnh/video đính kèm)*`]),
    ``
  );

  return lines.join("\n");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET") {
      return jsonResp({
        ok: true,
        service: "Garden Launcher Bug Report Bridge",
        version: "2.1",
        consolidatedBundle: true,
        mediaSupport: true,
        configured: Boolean(env.DISCORD_WEBHOOK_URL && env.REPORT_CLIENT_KEY),
        endpoint: `${url.origin}/report`,
      });
    }

    if (request.method !== "POST") {
      return jsonResp({ ok: false, error: "Method not allowed" }, 405);
    }

    if (!env.DISCORD_WEBHOOK_URL || !env.REPORT_CLIENT_KEY) {
      return jsonResp({ ok: false, error: "Máy chủ chưa cấu hình đầy đủ khóa bảo mật báo lỗi." }, 503);
    }

    const appHdr = request.headers.get("X-Garden-App") || "";
    const keyHdr = request.headers.get("X-Garden-Key") || "";
    if (appHdr !== "GardenLauncher-iOS" || keyHdr !== env.REPORT_CLIENT_KEY) {
      return jsonResp({ ok: false, error: "Yêu cầu không hợp lệ." }, 403);
    }

    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    let form;
    try {
      form = await request.formData();
    } catch {
      return jsonResp({ ok: false, error: "Dữ liệu gửi lên không đúng định dạng multipart/form-data." }, 400);
    }

    const deviceHash = clampStr(form.get("deviceHash"), 64, "anon");

    const category = clampStr(form.get("category"), 80, "Khác");
    const fullDescription = clampStr(form.get("description"), 8000, "");
    const embedDescription = clampStr(fullDescription, 2000, "");
    const contact = clampStr(form.get("contact"), 140, "Không cung cấp");
    const appVersion = clampStr(form.get("appVersion"), 40, "1.1.3");
    const iosVersion = clampStr(form.get("iosVersion"), 40, "?");
    const device = clampStr(form.get("device"), 64, "iPhone");
    const ramInfo = clampStr(form.get("ramInfo"), 120, "?");
    const controlMode = clampStr(form.get("controlMode"), 60, "?");
    const modCount = clampStr(form.get("modCount"), 32, "0");
    const fullModsSummary = clampStr(form.get("modsSummary"), 4000, "Không có");
    const embedModsSummary = clampStr(fullModsSummary, 950, "Không có");
    const fullIssueSummary = clampStr(form.get("issueSummary"), 4000, "");
    const embedIssueSummary = clampStr(fullIssueSummary, 900, "");

    if (fullDescription.length < 8) {
      return jsonResp({ ok: false, error: "Vui lòng nhập mô tả lỗi ít nhất 8 ký tự." }, 400);
    }

    let totalBytes = 0;

    // 1. Validate optional ErrorLogs.zip attachment
    let zipFile = null;
    const rawFile = form.get("file");
    if (rawFile && typeof rawFile === "object" && typeof rawFile.arrayBuffer === "function" && rawFile.size > 0) {
      if (rawFile.size > MAX_ZIP_BYTES) {
        return jsonResp({ ok: false, error: "Tệp ErrorLogs.zip vượt quá giới hạn 7.5 MB." }, 413);
      }
      const buf = await rawFile.arrayBuffer();
      const head = new Uint8Array(buf, 0, Math.min(4, buf.byteLength));
      if (head.length < 4 || head[0] !== 0x50 || head[1] !== 0x4b || head[2] !== 0x03 || head[3] !== 0x04) {
        return jsonResp({ ok: false, error: "Tệp đính kèm không phải định dạng .ZIP hợp lệ." }, 400);
      }
      zipFile = buf;
      totalBytes += buf.byteLength;
    }

    // 2. Validate up to 3 optional image/video attachments (media0, media1, media2)
    const mediaList = [];
    for (let i = 0; i < 3; i++) {
      const m = form.get(`media${i}`);
      if (!m || typeof m !== "object" || typeof m.arrayBuffer !== "function" || m.size <= 0) continue;
      if (m.size > MAX_MEDIA_BYTES) {
        return jsonResp({ ok: false, error: "Tệp ảnh/video vượt quá giới hạn 7.5 MB." }, 413);
      }
      const mbuf = await m.arrayBuffer();
      const det = detectAllowedMedia(mbuf, m.name || "");
      if (!det) {
        return jsonResp({ ok: false, error: "Chỉ hỗ trợ đính kèm hình ảnh (JPG/PNG/WEBP/GIF) và video (MP4/MOV)." }, 400);
      }
      if (totalBytes + mbuf.byteLength > MAX_TOTAL_BYTES) {
        return jsonResp({ ok: false, error: "Tổng dung lượng các tệp đính kèm vượt quá 9 MB." }, 413);
      }
      totalBytes += mbuf.byteLength;
      mediaList.push({ buf: mbuf, ext: det.ext, mime: det.mime });
    }

    // Only consume rate-limit quota AFTER payload validation passes!
    const rl = checkRateLimit(`${ip}|${deviceHash}`);
    if (!rl.ok) {
      return jsonResp({ ok: false, error: rl.reason }, 429);
    }

    const now = new Date();
    const dt = dosDateTime(now);
    const reportId = makeReportId();

    // 3. Collect all log entries & media entries into ONE consolidated ZIP package
    const bundleEntries = [];
    const logFileNames = [];
    const mediaFileNames = [];

    if (zipFile) {
      try {
        const parsedLogs = parseZipEntries(zipFile);
        for (const le of parsedLogs) {
          const targetName = `logs/${le.name}`;
          logFileNames.push(targetName);
          bundleEntries.push({ ...le, name: targetName });
        }
      } catch {
        // Fallback: preserve original zip intact if its layout is non-standard
        const rawLogName = `logs/ErrorLogs-${reportId}.zip`;
        logFileNames.push(rawLogName);
        bundleEntries.push(makeStoredEntry(rawLogName, new Uint8Array(zipFile), dt));
      }
    }

    for (let i = 0; i < mediaList.length; i++) {
      const m = mediaList[i];
      const mediaPath = `media/media-${reportId}-${i + 1}.${m.ext}`;
      mediaFileNames.push(mediaPath);
      bundleEntries.push(makeStoredEntry(mediaPath, new Uint8Array(m.buf), dt));
    }

    const reportMeta = {
      reportId,
      timestampIso: now.toISOString(),
      timestampVn: formatVnTimestamp(now),
      category,
      description: fullDescription,
      contact,
      appVersion,
      device,
      iosVersion,
      ramInfo,
      controlMode,
      modCount,
      modsSummary: fullModsSummary,
      issueSummary: fullIssueSummary,
      deviceHash,
      includedLogs: logFileNames,
      includedMedia: mediaFileNames,
    };

    const summaryMd = buildSummaryMarkdown(reportMeta, logFileNames, mediaFileNames);
    const metaJson = JSON.stringify(reportMeta, null, 2);

    // Place human-readable summary & JSON metadata at the top of the consolidated archive
    const finalEntries = [
      makeStoredEntry("00-BAO-LOI-TONG-HOP.md", textEncoder.encode(summaryMd), dt),
      makeStoredEntry("01-report-metadata.json", textEncoder.encode(metaJson), dt),
      ...bundleEntries,
    ];
    const consolidatedZip = buildZipArchive(finalEntries);
    const bundleFilename = `BugReport-${reportId}.zip`;

    // 4. Build rich Discord Embed + single consolidated bundle attachment
    const fields = [
      { name: "Loại lỗi", value: `\`${category}\``, inline: true },
      { name: "Phiên bản", value: `\`Garden Launcher v${appVersion}\``, inline: true },
      { name: "Thiết bị", value: `\`${device}\` · iOS \`${iosVersion}\``, inline: true },
      { name: "RAM", value: `\`${ramInfo}\``, inline: true },
      { name: "Điều khiển", value: `\`${controlMode}\``, inline: true },
      { name: "Liên hệ", value: contact, inline: true },
      { name: `Mod đang bật (${modCount})`, value: `\`\`\`\n${embedModsSummary}\n\`\`\``, inline: false },
    ];
    if (embedIssueSummary) {
      fields.push({ name: "Cảnh báo Mod Garden phát hiện", value: `\`\`\`\n${embedIssueSummary}\n\`\`\``, inline: false });
    }

    const bundleKb = Math.max(1, Math.round(consolidatedZip.byteLength / 1024));
    const packageSummary = [
      `📦 ${bundleFilename} (${bundleKb} KB)`,
      `Báo cáo tổng hợp + ${logFileNames.length} log`,
      ...(mediaFileNames.length ? [`${mediaFileNames.length} ảnh/video`] : []),
    ].join(" · ");

    const discordForm = new FormData();
    discordForm.append(
      "files[0]",
      new Blob([consolidatedZip], { type: "application/zip" }),
      bundleFilename
    );

    const payload = {
      username: "Garden Launcher Bug Bot",
      embeds: [
        {
          title: `🐞 Báo lỗi #${reportId} — ${category}`,
          description: embedDescription,
          color: categoryColor(category),
          fields,
          footer: { text: packageSummary },
          timestamp: now.toISOString(),
        },
      ],
      attachments: [{ id: 0, filename: bundleFilename }],
    };
    discordForm.append("payload_json", JSON.stringify(payload));

    const webhookUrl = env.DISCORD_WEBHOOK_URL.includes("?")
      ? `${env.DISCORD_WEBHOOK_URL}&wait=true`
      : `${env.DISCORD_WEBHOOK_URL}?wait=true`;

    const dResp = await fetch(webhookUrl, {
      method: "POST",
      body: discordForm,
    });

    if (!dResp.ok) {
      const errTxt = await dResp.text().catch(() => "");
      return jsonResp(
        { ok: false, error: `Discord từ chối gửi báo lỗi (HTTP ${dResp.status}).`, detail: errTxt.slice(0, 200) },
        502
      );
    }

    return jsonResp(
      {
        ok: true,
        reportId,
        bundleFilename,
        logCount: logFileNames.length,
        mediaCount: mediaFileNames.length,
      },
      200
    );
  },
};
