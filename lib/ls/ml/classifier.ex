defmodule LS.ML.Classifier do
  @moduledoc """
  Tier 2 classifier using sentence embeddings + cosine similarity.

  Uses `paraphrase-multilingual-MiniLM-L12-v2` to embed page text, then
  compares against pre-computed label embeddings to classify business model
  and industry. Multilingual, single forward pass per page, ~50ms on CPU.

  Only invoked when the heuristic BusinessClassifier returns low confidence.
  """

  use GenServer
  require Logger

  @model_repo "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
  @max_sequence_length 128
  @batch_size 8

  # Business model label descriptions — multiple per label for richer embeddings
  @bm_labels %{
    "SaaS" => [
      "software as a service cloud platform subscription pricing plans",
      "web application login dashboard API documentation developer tools",
      "SaaS product free trial sign up monthly annual billing"
    ],
    "Ecommerce" => [
      "online store shop buy products add to cart checkout shipping",
      "ecommerce shop collections new arrivals free shipping orders",
      "product catalog prices shopping cart retail store merchandise"
    ],
    "Agency" => [
      "digital agency creative services web design marketing branding portfolio",
      "agency our work clients case studies design development consulting",
      "marketing agency SEO social media content creation brand strategy"
    ],
    # Consulting = advisory/professional services ONLY. Its old labels
    # contained "contractor plumber electrician dentist ... clinic", which
    # made it swallow every physical business — golden v1 (2026-08-12)
    # measured Consulting at 64% precision largely because of that overlap.
    # Physical businesses now have their own class below.
    "Consulting" => [
      "professional services consulting firm advisory expertise",
      "management consulting strategy audit tax accounting legal advisory",
      "business services firm our clients engagements team of experts"
    ],
    "LocalBusiness" => [
      "local business physical store visit us opening hours address phone",
      "plumber electrician builder contractor local trade free quote fully insured",
      "clinic dentist salon gym restaurant hotel book an appointment book a table"
    ],
    "Media" => [
      "news media publication editorial journalism reporting articles blog",
      "online magazine editorial content breaking news opinion analysis",
      "media company publisher content platform digital publication"
    ],
    "Education" => [
      "online courses learning platform education training school university",
      "educational institution curriculum enrollment student programs degrees",
      "e-learning bootcamp classes tutorials certification training academy"
    ],
    # Tool / Community / Marketplace / Newsletter / Directory were REMOVED
    # from the ML label set on 2026-08-12. Golden v1 measured them at 0–33%
    # precision, and the reclassify harness showed most of those errors were
    # ML-sourced: zero-shot cosine on short page text cannot tell "has a
    # newsletter signup" from "is a newsletter" (the same trap the heuristic's
    # keyword layer had). Those classes are now assigned only by the heuristic
    # tier, which sees structure (title/H1/meta, pages, tech) and holds them
    # to a higher confidence bar. Re-adding any of them requires before/after
    # `mix ls.golden_reclassify` numbers proving the label set got separable.
  }

  # Industry label descriptions
  @industry_labels %{
    "Fintech" => [
      "financial technology banking payments lending investing cryptocurrency",
      "fintech payment processing digital banking money transfer trading"
    ],
    "Healthcare" => [
      "healthcare medical clinic hospital patient care telemedicine doctor",
      "health medical practice physician dental therapy wellness HIPAA"
    ],
    "Fashion" => [
      "fashion clothing apparel shoes jewelry accessories designer boutique",
      "fashion brand streetwear luxury clothing collection designer wear"
    ],
    "Beauty" => [
      "beauty skincare cosmetics makeup salon hair nail spa products",
      "beauty brand organic natural skin care wellness grooming"
    ],
    "Food & Beverage" => [
      "restaurant food delivery catering bakery coffee brewery dining",
      "food beverage menu recipes cooking ingredients organic gourmet"
    ],
    "Real Estate" => [
      "real estate property homes for sale rental listings mortgage",
      "real estate agent broker homes apartments commercial property"
    ],
    "Legal" => [
      "law firm attorney lawyer legal services litigation compliance",
      "legal practice personal injury family law corporate attorney"
    ],
    "Construction & Manufacturing" => [
      "construction contractor builder roofing plumbing electrical HVAC",
      "manufacturing industrial products factory building materials supply"
    ],
    "DevTools" => [
      "developer tools API SDK programming code software development",
      "devops CI CD infrastructure monitoring deployment hosting platform"
    ],
    "AI & ML" => [
      "artificial intelligence machine learning AI powered deep learning",
      "AI platform GPT LLM neural network computer vision NLP automation"
    ],
    "Marketing" => [
      "marketing platform email marketing SEO PPC CRM lead generation",
      "marketing automation analytics advertising campaign management"
    ],
    "Security" => [
      "cybersecurity information security threat detection vulnerability",
      "security platform SIEM endpoint protection firewall zero trust"
    ],
    "HR & Recruiting" => [
      "human resources recruiting hiring payroll onboarding talent management",
      "HR platform applicant tracking workforce management employee engagement"
    ],
    "Education" => [
      "education school university academic curriculum student learning",
      "educational institution research academic programs degrees campus"
    ],
    "Travel" => [
      "travel tourism hotel booking vacation flights destination tours",
      "travel agency trip planning accommodation resort adventure tourism"
    ],
    "Media & Entertainment" => [
      "entertainment streaming gaming music video podcast production",
      "media entertainment content creation studio film production digital"
    ],
    "Home & Garden" => [
      "home improvement interior design furniture decor garden landscaping",
      "home garden renovation decoration furnishing DIY home repair"
    ],
    "Logistics" => [
      "logistics shipping supply chain fleet management warehouse delivery",
      "freight tracking transportation courier fulfillment distribution"
    ],
    "Productivity" => [
      "productivity project management task management workflow collaboration",
      "productivity tool team communication organization time management"
    ],
    "Ecommerce & Retail" => [
      "ecommerce retail online shopping platform multi-channel selling",
      "retail technology point of sale inventory management omnichannel"
    ]
  }

  # =========================================================================
  # PUBLIC API
  # =========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Classify text into business model and industry.

  Input: a string (typically title + h1 + meta_desc + body snippet).
  Returns: %{business_model: String, industry: String, ml_confidence: float}
  """
  def classify(text) when is_binary(text) and byte_size(text) > 0 do
    GenServer.call(__MODULE__, {:classify, text}, 15_000)
  catch
    :exit, _ -> %{business_model: "", industry: "", ml_confidence: 0.0}
  end
  def classify(_), do: %{business_model: "", industry: "", ml_confidence: 0.0}

  @doc "Classify a batch of texts. Returns a list of classification results."
  def classify_batch(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:classify_batch, texts}, 120_000)
  catch
    :exit, _ -> Enum.map(texts, fn _ -> %{business_model: "", industry: "", ml_confidence: 0.0} end)
  end

  @doc "Check if the ML classifier is loaded and ready."
  def ready? do
    GenServer.call(__MODULE__, :ready?, 5_000)
  catch
    :exit, _ -> false
  end

  @doc """
  Raw L2-normalized MiniLM embeddings (384 floats) for a batch of texts.

  This is the feature extractor for the trained classification head (the
  distillation program, docs/data-quality.md): training computes embeddings
  for teacher-labeled pages, and runtime inference applies the head to the
  same embeddings. Returns a list of float lists in input order; `nil` per
  entry on empty input.
  """
  def embed_batch(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:embed_batch, texts}, 300_000)
  catch
    :exit, _ -> Enum.map(texts, fn _ -> nil end)
  end

  # =========================================================================
  # GENSERVER
  # =========================================================================

  @impl true
  def init(_opts) do
    # Load model asynchronously to not block app startup
    send(self(), :load_model)
    {:ok, %{serving: nil, bm_embeddings: nil, industry_embeddings: nil, head: nil, ready: false}}
  end

  @impl true
  def handle_info(:load_model, state) do
    Logger.info("🧠 ML Classifier: loading #{@model_repo}...")

    try do
      {:ok, model_info} = Bumblebee.load_model({:hf, @model_repo})
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_repo})

      serving = Bumblebee.Text.text_embedding(model_info, tokenizer,
        compile: [batch_size: @batch_size, sequence_length: @max_sequence_length],
        output_pool: :mean_pooling,
        output_attribute: :hidden_state,
        embedding_processor: :l2_norm,
        defn_options: [compiler: EXLA]
      )

      Logger.info("🧠 ML Classifier: model loaded, computing label embeddings...")

      bm_embeddings = compute_label_embeddings(serving, @bm_labels)
      industry_embeddings = compute_label_embeddings(serving, @industry_labels)

      Logger.info("🧠 ML Classifier: ready (#{map_size(bm_embeddings)} BM labels, #{map_size(industry_embeddings)} industry labels)")

      head = LS.ML.Head.load()
      if head, do: Logger.info("🧠 ML Head loaded: #{head.version}")

      {:noreply, %{serving: serving, bm_embeddings: bm_embeddings,
                    industry_embeddings: industry_embeddings, head: head, ready: true}}
    rescue
      e ->
        Logger.error("🧠 ML Classifier: failed to load — #{Exception.message(e)}")
        # Retry in 30 seconds
        Process.send_after(self(), :load_model, 30_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.ready, state}
  end

  @impl true
  def handle_call({:classify, _text}, _from, %{ready: false} = state) do
    {:reply, %{business_model: "", industry: "", ml_confidence: 0.0}, state}
  end

  @impl true
  def handle_call({:classify, text}, _from, state) do
    result = safe_classify(text, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:classify_batch, texts}, _from, %{ready: false} = state) do
    empty = Enum.map(texts, fn _ -> %{business_model: "", industry: "", ml_confidence: 0.0} end)
    {:reply, empty, state}
  end

  @impl true
  def handle_call({:classify_batch, texts}, _from, state) do
    # TRUE batching (2026-07-27): one Nx.Serving.run per chunk instead of one
    # per text. The serving is compiled with batch_size 8, so single-text calls
    # were already paying for the 8-wide kernel and padding 7 slots with zeros —
    # batching simply fills those slots with real work. Per-item math is
    # unchanged: transformer attention/LayerNorm never mix batch items, and
    # score_embedding/2 is the same code the single path uses.
    results =
      texts
      |> Enum.chunk_every(32)
      |> Enum.flat_map(fn chunk -> do_classify_chunk(chunk, state) end)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:embed_batch, texts}, _from, %{ready: false} = state) do
    {:reply, Enum.map(texts, fn _ -> nil end), state}
  end

  @impl true
  def handle_call({:embed_batch, texts}, _from, state) do
    results =
      texts
      |> Enum.chunk_every(32)
      |> Enum.flat_map(fn chunk ->
        sanitized = Enum.map(chunk, &sanitize_text/1)

        try do
          state.serving
          |> Nx.Serving.run(sanitized)
          |> Enum.map(fn %{embedding: emb} -> Nx.to_flat_list(emb) end)
        rescue
          e ->
            Logger.warning("ML Classifier: embed chunk failed — #{Exception.message(e)}")
            Enum.map(chunk, fn _ -> nil end)
        end
      end)

    {:reply, results, state}
  end

  # =========================================================================
  # CLASSIFICATION LOGIC
  # =========================================================================

  @empty_classification %{business_model: "", industry: "", ml_confidence: 0.0,
                           ml_bm_confidence: 0.0, ml_industry_confidence: 0.0}

  defp safe_classify(text, state) do
    do_classify(text, state)
  rescue
    e ->
      Logger.warning("ML Classifier: skipping text (#{byte_size(text)} bytes) — #{Exception.message(e)}")
      @empty_classification
  end

  defp do_classify_chunk(chunk, state) do
    sanitized = Enum.map(chunk, &sanitize_text/1)

    outputs = Nx.Serving.run(state.serving, sanitized)

    Enum.map(outputs, fn %{embedding: emb} -> score_embedding(emb, state) end)
  rescue
    e ->
      Logger.warning("ML Classifier: batched chunk failed (#{Exception.message(e)}) — falling back to per-text")
      Enum.map(chunk, &safe_classify(&1, state))
  end

  defp sanitize_text(text) do
    text = if String.valid?(text) do
      text
    else
      case :unicode.characters_to_binary(text, :utf8, :utf8) do
        {:error, good, _} -> good
        {:incomplete, good, _} -> good
        bin when is_binary(bin) -> bin
      end
    end

    String.slice(text, 0, 500)
  end

  defp do_classify(text, state) do
    text = sanitize_text(text)

    # Get embedding for input text
    %{embedding: text_embedding} = Nx.Serving.run(state.serving, text)

    score_embedding(text_embedding, state)
  end

  # Shared post-embedding scoring — the ONLY scoring code, used by both the
  # single and the batched path, so their results are identical by construction.
  defp score_embedding(text_embedding, state) do
    # Business model: trained head when available (calibrated confidence),
    # zero-shot cosine as fallback. Industry keeps the cosine path — the head
    # was trained on business_model only.
    {bm, bm_conf_raw} = score_business_model(text_embedding, state)

    # Find best industry
    {industry, ind_score} = find_best_match(text_embedding, state.industry_embeddings)

    bm_conf = bm_conf_raw
    ind_conf = normalize_score(ind_score)

    # bm floor 0.4→0.5 and stored confidence capped at 0.85: golden v1's
    # worst calibration failures (Community@0.94–0.98 on a JP software shop
    # and an Iranian network integrator) were ML-sourced — short non-English
    # text produces inflated cosines, so the ML tier may never claim the
    # top confidence band on its own. 0.5 won the measured sweep (0.45 diluted
    # Agency to 44% by force-matching non-English pages; 0.58 cut coverage to
    # 39% without buying precision). Uncertain rows stay unclassified for the
    # future LLM tier rather than being sold wrong.
    %{
      business_model: if(bm_conf >= 0.5, do: bm, else: ""),
      industry: if(ind_conf >= 0.35, do: industry, else: ""),
      ml_confidence: Float.round(min(max(bm_conf, ind_conf), 0.85), 2),
      ml_bm_confidence: Float.round(bm_conf, 2),
      ml_industry_confidence: Float.round(ind_conf, 2)
    }
  end

  # Head path: calibrated 13-class softmax (see LS.ML.Head). A "Junk" vote is
  # a decline-to-classify, not a label — is_junk stays owned by junk_reason/1.
  # Cosine fallback keeps the tier alive if the weights file is broken.
  defp score_business_model(text_embedding, %{head: head}) when not is_nil(head) do
    case LS.ML.Head.predict(head, text_embedding) do
      {"Junk", _prob} -> {"", 0.0}
      {class, prob} -> {class, Float.round(prob, 2)}
    end
  end

  defp score_business_model(text_embedding, state) do
    {bm, bm_score} = find_best_match(text_embedding, state.bm_embeddings)
    {bm, normalize_score(bm_score)}
  end

  defp find_best_match(text_embedding, label_embeddings) do
    label_embeddings
    |> Enum.map(fn {label, label_emb} ->
      # Both embeddings are already L2-normalized, so dot product = cosine similarity
      score = Nx.dot(text_embedding, label_emb) |> Nx.to_number()
      {label, score}
    end)
    |> Enum.max_by(fn {_, score} -> score end)
  end

  # Map cosine similarity (typically 0.1-0.7) to confidence (0.0-1.0)
  defp normalize_score(cosine_sim) do
    # Empirical mapping: 0.2 = low, 0.4 = medium, 0.6+ = high
    score = (cosine_sim - 0.15) / 0.45
    score |> max(0.0) |> min(1.0)
  end

  # =========================================================================
  # LABEL EMBEDDING COMPUTATION
  # =========================================================================

  defp compute_label_embeddings(serving, label_map) do
    label_map
    |> Enum.map(fn {label, descriptions} ->
      # Embed all descriptions for this label
      embeddings = descriptions
      |> Enum.map(fn desc ->
        %{embedding: emb} = Nx.Serving.run(serving, desc)
        emb
      end)

      # Average the embeddings and re-normalize
      stacked = Nx.stack(embeddings)
      mean = Nx.mean(stacked, axes: [0])
      norm = Nx.LinAlg.norm(mean)
      normalized = Nx.divide(mean, norm)

      {label, normalized}
    end)
    |> Map.new()
  end
end
