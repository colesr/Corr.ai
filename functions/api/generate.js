// Cloudflare Pages Function — POST /api/generate
// Calls Workers AI to produce one unexpected correlation as JSON.
// Requires an AI binding named "AI" in the Pages project settings.
// Returns the parsed card plus transparency metadata (raw model output,
// prompts, model name, timings) so the client can render an audit trail.

const MODEL = "@cf/meta/llama-3.1-8b-instruct";

export async function onRequest({ request, env }) {
  if (request.method !== "POST") {
    return json({ error: "POST only" }, 405);
  }
  if (!env.AI) {
    return json({
      error: "Workers AI binding not configured. In the Cloudflare Pages " +
        "project settings → Functions → Bindings, add an AI binding with " +
        "variable name 'AI'.",
    }, 500);
  }

  let body = {};
  try { body = await request.json(); } catch {}
  const seed = String(body.seed || "").slice(0, 200).trim();

  const system = `You are CORR.AI, a generator of unexpected, thought-provoking correlations between two real-world variables. Each output is a hypothesis for an "odd correlation engine" — pairings that are statistically curious because of confounders, coincidences, or genuine shared mechanisms.

Output a single JSON object with these exact fields and nothing else:
{
  "title": "A short headline in 'X ↔ Y' form",
  "a": "Specific description of variable A (mention units if applicable)",
  "b": "Specific description of variable B (mention units if applicable)",
  "domains": ["array of 2-4 lowercase tags from: food, climate, biology, society, academia, statistics, transport, language, weather, history, satire, folklore, public-health, film"],
  "strength": 0.7,
  "summary": "1-2 sentence summary of the correlation",
  "why": "2-3 sentences on why the correlation might appear: shared confounder, coincidence, or genuine causal link"
}

Rules:
- "strength" must be a number between -1 and 1 (the hypothesized correlation coefficient).
- Be creative, specific, and slightly contrarian. Avoid generic pairings like "rain ↔ umbrella sales".
- Respond with the JSON object only. No prose, no markdown fences.`;

  const user = seed
    ? `Generate a correlation using this seed for inspiration: "${seed}"`
    : `Generate one unexpected correlation right now. Surprise me.`;

  const startedAt = Date.now();
  try {
    const result = await env.AI.run(MODEL, {
      messages: [
        { role: "system", content: system },
        { role: "user", content: user },
      ],
      max_tokens: 500,
      temperature: 0.95,
    });
    const durationMs = Date.now() - startedAt;

    const raw = String(result?.response || "").trim();
    const parsed = extractJson(raw);

    if (!parsed) {
      return json({
        error: "model returned non-JSON",
        raw,
        model: MODEL,
        durationMs,
        prompt: { system, user },
      }, 502);
    }

    // Light validation + defaults so the client can render unconditionally.
    parsed.source = "generated";
    if (!Array.isArray(parsed.domains)) parsed.domains = ["generated"];
    if (typeof parsed.strength !== "number") parsed.strength = 0;
    parsed.strength = Math.max(-1, Math.min(1, parsed.strength));
    parsed.title   = String(parsed.title   || "Untitled correlation");
    parsed.a       = String(parsed.a       || "");
    parsed.b       = String(parsed.b       || "");
    parsed.summary = String(parsed.summary || "");
    parsed.why     = String(parsed.why     || "");

    return json({
      card: parsed,
      model: MODEL,
      durationMs,
      prompt: { system, user },
      raw,
    });
  } catch (e) {
    return json({
      error: e?.message || "AI call failed",
      model: MODEL,
      durationMs: Date.now() - startedAt,
      prompt: { system, user },
    }, 502);
  }
}

function extractJson(text) {
  const cleaned = text.replace(/^```(?:json)?\s*|\s*```\s*$/g, "").trim();
  try { return JSON.parse(cleaned); } catch {}
  const m = cleaned.match(/\{[\s\S]*\}/);
  if (m) { try { return JSON.parse(m[0]); } catch {} }
  return null;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
