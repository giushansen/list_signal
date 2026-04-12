defmodule LSWeb.RedirectController do
  use LSWeb, :controller

  def signup(conn, params) do
    query_params =
      []
      |> then(fn q -> if params["plan"] in ["starter", "pro"], do: [{"plan", params["plan"]} | q], else: q end)
      |> then(fn q -> if params["billing"] in ["monthly", "annual"], do: [{"billing", params["billing"]} | q], else: q end)

    target = case query_params do
      [] -> "/users/register"
      _ -> "/users/register?" <> URI.encode_query(query_params)
    end

    redirect(conn, to: target)
  end

  def login(conn, _params) do
    redirect(conn, to: ~p"/users/log-in")
  end

  @country_slug_to_code %{
    "united-states" => "us", "united-kingdom" => "gb", "canada" => "ca",
    "australia" => "au", "germany" => "de", "france" => "fr", "netherlands" => "nl",
    "sweden" => "se", "japan" => "jp", "south-korea" => "kr", "india" => "in",
    "brazil" => "br", "new-zealand" => "nz", "ireland" => "ie", "singapore" => "sg",
    "italy" => "it", "spain" => "es", "denmark" => "dk", "norway" => "no",
    "finland" => "fi", "belgium" => "be", "switzerland" => "ch", "austria" => "at",
    "poland" => "pl", "portugal" => "pt", "mexico" => "mx", "israel" => "il",
    "hong-kong" => "hk", "taiwan" => "tw", "uae" => "ae", "south-africa" => "za",
    "china" => "cn", "russia" => "ru", "turkey" => "tr", "czech-republic" => "cz",
    "hungary" => "hu", "romania" => "ro", "greece" => "gr", "ukraine" => "ua",
    "thailand" => "th", "vietnam" => "vn", "indonesia" => "id", "malaysia" => "my",
    "argentina" => "ar", "colombia" => "co", "chile" => "cl", "peru" => "pe",
    "philippines" => "ph", "nigeria" => "ng", "egypt" => "eg", "kenya" => "ke",
    "saudi-arabia" => "sa", "pakistan" => "pk", "bangladesh" => "bd"
  }

  def store_country(conn, %{"slug" => slug}) do
    case Map.get(@country_slug_to_code, slug) do
      nil -> conn |> put_status(404) |> text("Not found")
      code -> redirect(conn, to: "/top/shopify-stores-#{code}")
    end
  end
end
