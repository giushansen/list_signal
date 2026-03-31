defmodule LS.HTTP.SchemaExtractor do
  @moduledoc "Extracts Schema.org JSON-LD @type and og:type from HTML."

  # Most specific → least specific
  @schema_priority [
    # Healthcare
    "Dentist", "Physician", "Hospital", "Pharmacy", "MedicalClinic", "MedicalOrganization",
    # Legal
    "LegalService", "Attorney", "Notary",
    # Food
    "Restaurant", "CafeOrCoffeeShop", "Bakery", "BarOrPub", "FastFoodRestaurant", "Brewery",
    # Real Estate
    "RealEstateAgent",
    # Finance
    "BankOrCreditUnion", "InsuranceAgency", "AccountingService", "FinancialService",
    # Stores
    "ClothingStore", "ElectronicsStore", "JewelryStore", "GroceryStore", "FurnitureStore",
    "PetStore", "ShoeStore", "SportingGoodsStore", "ToyStore", "HardwareStore",
    "HomeGoodsStore", "LiquorStore", "MusicStore", "OfficeEquipmentStore",
    # Beauty
    "BeautySalon", "HairSalon", "NailSalon", "DaySpa",
    # Construction
    "Electrician", "Plumber", "RoofingContractor", "GeneralContractor", "HVACBusiness",
    # Travel
    "TravelAgency", "Hotel", "LodgingBusiness",
    # Education
    "EducationalOrganization", "School", "CollegeOrUniversity", "Course",
    # Software
    "SoftwareApplication", "WebApplication", "MobileApplication",
    # Products
    "Product", "IndividualProduct",
    # Media
    "NewsMediaOrganization",
    # Generic (lowest priority)
    "Store", "LocalBusiness", "Organization", "WebSite"
  ]

  @schema_set MapSet.new(@schema_priority)
  @schema_rank @schema_priority |> Enum.with_index() |> Map.new()

  @doc "Extracts Schema.org @type from JSON-LD, returning most specific type found."
  def extract_schema_type(nil), do: ""
  def extract_schema_type(body) when is_binary(body) do
    Regex.scan(~r/<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>(.*?)<\/script>/is, body)
    |> Enum.flat_map(fn [_, json_str] ->
      case Jason.decode(json_str) do
        {:ok, data} -> extract_types(data)
        _ -> []
      end
    end)
    |> Enum.filter(&MapSet.member?(@schema_set, &1))
    |> Enum.sort_by(&Map.get(@schema_rank, &1, 999))
    |> List.first("")
  rescue
    _ -> ""
  end
  def extract_schema_type(_), do: ""

  @doc "Extracts og:type meta tag content, lowercase."
  def extract_og_type(nil), do: ""
  def extract_og_type(body) when is_binary(body) do
    case Regex.run(~r/<meta[^>]*property\s*=\s*["']og:type["'][^>]*content\s*=\s*["']([^"']+)["']/is, body) do
      [_, t] -> String.downcase(String.trim(t))
      _ ->
        case Regex.run(~r/<meta[^>]*content\s*=\s*["']([^"']+)["'][^>]*property\s*=\s*["']og:type["']/is, body) do
          [_, t] -> String.downcase(String.trim(t))
          _ -> ""
        end
    end
  rescue
    _ -> ""
  end
  def extract_og_type(_), do: ""

  # Recursively extract @type from JSON-LD data (handles arrays and @graph)
  defp extract_types(%{"@graph" => items}) when is_list(items) do
    Enum.flat_map(items, &extract_types/1)
  end
  defp extract_types(%{"@type" => types}) when is_list(types), do: List.flatten(types)
  defp extract_types(%{"@type" => type}) when is_binary(type), do: [type]
  defp extract_types(items) when is_list(items), do: Enum.flat_map(items, &extract_types/1)
  defp extract_types(_), do: []
end
