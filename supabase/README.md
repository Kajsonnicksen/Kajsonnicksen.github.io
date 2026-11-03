# Supabase setup

## Madfotoanalyse

Madfotoanalyse kræver en Supabase Edge Function og en OpenAI API-nøgle. Nøglen skal **kun** ligge i Supabase Secrets; læg den aldrig i `supabase-config.js`, GitHub Pages eller chatten.

1. I Supabase Dashboard: åbn projektet → **Edge Functions** → opret `analyze-food`.
2. Indsæt indholdet fra `functions/analyze-food/index.ts`, og deploy funktionen. `config.toml` angiver, at login-JWT skal kræves.
3. Åbn **Edge Function Secrets** og tilføj `OPENAI_API_KEY` med din egen OpenAI API-nøgle.
4. Genindlæs appen på `https://kajsonnicksen.github.io`, vælg et billede i fanen **Kost**, og tryk **Analyser madfoto**.

Funktionen accepterer kun kald med brugerens Supabase-login. Den returnerer portions- og næringsestimater, som du kan rette før du tilføjer dem. Billedet sendes til OpenAI via serverfunktionen; estimater fra foto kan være upræcise.

## Fødevaresøgning

Søgningen kombinerer en lille lokal liste med almindelige råvarer, USDA FoodData Central og Open Food Facts. USDA's `DEMO_KEY` har lave fælles hastighedsgrænser. Hvis den kilde begynder at afvise søgninger, kan der oprettes en gratis USDA API-nøgle og anvendes fra en serverfunktion; nøglen må ikke lægges i den offentlige frontend.

