const allowedOrigins = new Set([
  "https://kajsonnicksen.github.io",
  "http://localhost:5173",
  "http://127.0.0.1:5173",
]);

function corsHeaders(origin: string | null) {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  if (origin && allowedOrigins.has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  const headers = corsHeaders(origin);
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (origin && !allowedOrigins.has(origin)) {
    return Response.json({ error: "Origin not allowed" }, { status: 403, headers });
  }
  if (req.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405, headers });
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) return Response.json({ error: "AI is not configured" }, { status: 503, headers });

  try {
    const body = await req.json();
    const image = typeof body?.image === "string" ? body.image : "";
    if (!/^data:image\/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$/.test(image) || image.length > 7_000_000) {
      return Response.json({ error: "Send one JPEG, PNG, or WebP image up to 5 MB." }, { status: 400, headers });
    }

    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        temperature: 0.1,
        max_tokens: 900,
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "food_photo_analysis",
            strict: true,
            schema: {
              type: "object",
              additionalProperties: false,
              required: ["foods", "notes"],
              properties: {
                foods: {
                  type: "array",
                  items: {
                    type: "object",
                    additionalProperties: false,
                    required: ["name", "grams", "kcal", "protein", "carbs", "fat"],
                    properties: {
                      name: { type: "string" },
                      grams: { type: "number" },
                      kcal: { type: "number" },
                      protein: { type: "number" },
                      carbs: { type: "number" },
                      fat: { type: "number" },
                    },
                  },
                },
                notes: { type: "string" },
              },
            },
          },
        },
        messages: [
          {
            role: "system",
            content: "Identify visible foods in the meal photo. Return at most 6 distinct foods. Estimate the edible portion in grams and total calories, protein, carbohydrates and fat for each visible portion, using reasonable typical nutrition values. Do not invent hidden ingredients. If the image is not food or no food can be identified, return an empty foods array. These are estimates, not exact measurements. Write names and notes in Danish.",
          },
          {
            role: "user",
            content: [
              { type: "text", text: "Identificér maden og estimér portionsstørrelse og næringsindhold." },
              { type: "image_url", image_url: { url: image, detail: "low" } },
            ],
          },
        ],
      }),
    });

    if (!response.ok) {
      console.error("OpenAI food analysis failed with status", response.status);
      return Response.json({ error: "Food photo analysis provider failed." }, { status: 502, headers });
    }
    const result = await response.json();
    const content = result.choices?.[0]?.message?.content;
    if (typeof content !== "string") throw new Error("Missing model response");
    const parsed = JSON.parse(content);
    const foods = (Array.isArray(parsed.foods) ? parsed.foods : []).slice(0, 6).map((food: Record<string, unknown>) => ({
      name: String(food.name || "Mad" ).slice(0, 100),
      grams: clamp(food.grams, 1, 5000),
      kcal: clamp(food.kcal, 0, 10000),
      protein: clamp(food.protein, 0, 1000),
      carbs: clamp(food.carbs, 0, 1000),
      fat: clamp(food.fat, 0, 1000),
    }));
    return Response.json({ foods, notes: String(parsed.notes || "") }, { headers });
  } catch (error) {
    console.error("Food photo analysis request failed", error instanceof Error ? error.message : "unknown error");
    return Response.json({ error: "Could not analyze this image." }, { status: 400, headers });
  }
});

function clamp(value: unknown, min: number, max: number): number {
  const n = Number(value);
  return Number.isFinite(n) ? Math.min(max, Math.max(min, n)) : min;
}

