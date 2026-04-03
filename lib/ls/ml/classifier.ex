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
    "Consulting" => [
      "professional services consulting firm local business service provider",
      "contractor plumber electrician dentist lawyer accountant clinic",
      "local service company appointments contact us about our services"
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
    "Tool" => [
      "free online tool calculator converter checker generator utility",
      "website builder theme marketplace templates plugins extensions",
      "developer tool code editor IDE productivity utilities open source"
    ],
    "Community" => [
      "community forum discussion board members groups social network",
      "online community join us membership connect with others conversations",
      "forum discussion topics threads user community social platform"
    ],
    "Marketplace" => [
      "marketplace buy and sell connect buyers sellers platform listings",
      "peer to peer marketplace vendors merchants third party sellers",
      "multi-vendor marketplace listing fees commission transactions"
    ],
    "Newsletter" => [
      "newsletter weekly digest daily briefing email subscription updates",
      "subscribe to our newsletter email list content updates weekly",
      "substack newsletter writing publishing email audience subscribers"
    ],
    "Directory" => [
      "business directory listing search find local businesses categories",
      "directory submit your listing browse categories search listings",
      "yellow pages directory find businesses reviews ratings categories"
    ]
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
    GenServer.call(__MODULE__, {:classify_batch, texts}, 30_000)
  catch
    :exit, _ -> Enum.map(texts, fn _ -> %{business_model: "", industry: "", ml_confidence: 0.0} end)
  end

  @doc "Check if the ML classifier is loaded and ready."
  def ready? do
    GenServer.call(__MODULE__, :ready?, 5_000)
  catch
    :exit, _ -> false
  end

  # =========================================================================
  # GENSERVER
  # =========================================================================

  @impl true
  def init(_opts) do
    # Load model asynchronously to not block app startup
    send(self(), :load_model)
    {:ok, %{serving: nil, bm_embeddings: nil, industry_embeddings: nil, ready: false}}
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

      {:noreply, %{serving: serving, bm_embeddings: bm_embeddings,
                    industry_embeddings: industry_embeddings, ready: true}}
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
    results = Enum.map(texts, &safe_classify(&1, state))
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

  defp do_classify(text, state) do
    # Ensure valid UTF-8 — pages may contain Windows-1251, Latin-1, etc.
    text = if String.valid?(text) do
      text
    else
      case :unicode.characters_to_binary(text, :utf8, :utf8) do
        {:error, good, _} -> good
        {:incomplete, good, _} -> good
        bin when is_binary(bin) -> bin
      end
    end

    # Truncate input to reasonable length
    text = String.slice(text, 0, 500)

    # Get embedding for input text
    %{embedding: text_embedding} = Nx.Serving.run(state.serving, text)

    # Find best business model
    {bm, bm_score} = find_best_match(text_embedding, state.bm_embeddings)

    # Find best industry
    {industry, ind_score} = find_best_match(text_embedding, state.industry_embeddings)

    # Confidence = average of the two best scores, scaled
    # Cosine similarity ranges from -1 to 1, typical good matches are 0.3-0.7
    bm_conf = normalize_score(bm_score)
    ind_conf = normalize_score(ind_score)

    %{
      business_model: if(bm_conf >= 0.4, do: bm, else: ""),
      industry: if(ind_conf >= 0.35, do: industry, else: ""),
      ml_confidence: Float.round(max(bm_conf, ind_conf), 2),
      ml_bm_confidence: Float.round(bm_conf, 2),
      ml_industry_confidence: Float.round(ind_conf, 2)
    }
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
