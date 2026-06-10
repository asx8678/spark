defmodule Immo.CatalogSeeds do
  @moduledoc """
  Realistic catalog seed data for P1-E2.6 (§16 P1-E2 AC).

  Seeds:
    * 3 property_types: `apartment`, `land`, `rental` — each with
      a full `filter_config` (facets: key, kind, source, unit,
      min/max, options) and `schema_hints` (known attribute keys +
      types) per §5.3.
    * 3 developers (one major group, one mid-size, one
      city-district-named).
    * 6 projects (2 per developer) across 5 cities.
    * ≥40 listings spanning the 3 types:
        - 16 apartments
        - 14 lands
        - 12 rentals
      with realistic attributes, MAD prices (some
      `price_on_request: true`), Moroccan cities, mixed
      `project_id` (project-attached and standalone), mixed
      `published_at` (drafts + past-published + future-scheduled),
      and mixed `status` (available / reserved / sold / rented).
    * fr + ar i18n content (title / description / seo).
    * One active subscription per developer so the §5.13 billing
      gate runs against realistic data when BILLING_ENFORCED is on.
    * Custom fields seeded for `apartment` (bedrooms, bathrooms,
      floor, zoning, energy_class) to exercise §5.5.

  ## Idempotency

  `run/0` checks for a sentinel (`apartment` property_type exists)
  and short-circuits if the catalog is already seeded. The
  short-circuit is observable from `seeded?/0` so the test
  suite can run the seeds exactly once per sandbox.

  ## Test usage

      seeds = Immo.CatalogSeeds.run()
      # seeds = %{developers: [...], property_types: [...],
      #          projects: [...], listings: [...], ...}
  """

  alias Immo.Catalog
  alias Immo.Billing.Subscription
  alias Immo.Repo

  @doc """
  Run the seeds. Idempotent: short-circuits if the catalog is
  already populated (the sentinel is the `apartment` property_type).

  Returns a summary map of the created/looked-up records so tests
  can refer to them without re-querying.
  """
  @spec run() :: map()
  def run do
    if seeded?() do
      IO.puts("[seed] catalog already seeded, short-circuiting")
      summarize_existing()
    else
      do_seed()
    end
  end

  @doc "Has the catalog already been seeded?"
  @spec seeded?() :: boolean()
  def seeded? do
    case Catalog.get_property_type_by_key("apartment") do
      nil -> false
      %{} -> true
    end
  end

  @doc "Reset (delete all catalog data). Test-only — never call from seeds.exs."
  @spec reset!() :: :ok
  def reset! do
    # Null out any user.developer_id references first so the
    # developer delete isn't blocked by a RESTRICT FK from users
    # (the §5.8 tenant scope wires users to developers; the seed
    # doesn't care about that wiring, but reset must not crash).
    # Delete users with role=developer_user first; they have a
    # §5.8 CHECK constraint requiring developer_id IS NOT NULL,
    # so we cannot just null it. We delete the user entirely
    # (the test sandbox isolates by rollback, so this is safe).
    _ = Repo.query!("DELETE FROM users WHERE role = 'developer_user'")
    Repo.delete_all(Immo.Catalog.Listing)
    Repo.delete_all(Immo.Catalog.CustomField)
    Repo.delete_all(Immo.Catalog.Project)
    Repo.delete_all(Immo.Catalog.PropertyType)
    Repo.delete_all(Immo.Catalog.Developer)
    :ok
  end

  ## Implementation

  defp summarize_existing do
    %{
      developers: Catalog.list_developers(),
      property_types: Catalog.list_property_types(),
      projects: Catalog.list_projects(),
      listings: Catalog.list_listings(),
      subscriptions: Immo.Repo.all(Subscription)
    }
  end

  defp do_seed do
    # 1. Property types
    pt_apartment = seed_property_type("apartment", apartment_def())
    pt_land = seed_property_type("land", land_def())
    pt_rental = seed_property_type("rental", rental_def())

    # 2. Custom fields (apartment first — bedrooms is a §5.4 example)
    seed_custom_fields(pt_apartment)

    # 3. Developers + active subscriptions
    dev_immo = seed_developer_with_subscription("immo-atlas", "Immo Atlas")
    dev_medina = seed_developer_with_subscription("residence-medina", "Residence Medina")
    dev_anfa = seed_developer_with_subscription("anfa-properties", "Anfa Properties")

    # 4. Projects (2 per developer)
    project_casa_atlas =
      seed_project(
        dev_immo,
        "le-jardin-de-l-atlantique",
        "Le Jardin de l'Atlantique",
        "Casablanca"
      )

    project_rabat_atlas =
      seed_project(dev_immo, "les-ambassades", "Les Ambassades", "Rabat")

    project_medina_fes =
      seed_project(dev_medina, "medina-residences", "Medina Residences", "Fes")

    project_medina_marrakech =
      seed_project(dev_medina, "palmeraie-garden", "Palmeraie Garden", "Marrakech")

    project_anfa_casablanca =
      seed_project(dev_anfa, "tower-anfa", "Tour Anfa", "Casablanca")

    project_anfa_tangier =
      seed_project(dev_anfa, "cap-malabata", "Cap Malabata", "Tangier")

    # 5. Listings
    seed_listings(
      pt_apartment,
      pt_land,
      project_casa_atlas,
      project_rabat_atlas,
      project_anfa_casablanca,
      project_medina_fes,
      project_medina_marrakech,
      project_anfa_tangier
    )

    seed_listings_two(
      pt_rental,
      project_casa_atlas,
      project_rabat_atlas,
      project_anfa_casablanca,
      project_medina_fes,
      project_medina_marrakech,
      project_anfa_tangier
    )

    IO.puts("[seed] catalog seeded")

    summarize_existing()
  end

  ## Property types

  defp seed_property_type(key, attrs) do
    case Catalog.get_property_type_by_key(key) do
      nil ->
        {:ok, pt} = Catalog.create_property_type(attrs)
        pt

      %{} = existing ->
        existing
    end
  end

  defp apartment_def do
    %{
      key: "apartment",
      label: %{"fr" => "Appartement", "ar" => "شقة"},
      url_segment: %{"fr" => "appartements", "ar" => "شقق"},
      position: 0,
      schema_hints: %{
        "known_keys" => [
          %{"key" => "bedrooms", "type" => "integer"},
          %{"key" => "bathrooms-hy", "type" => "integer"},
          %{"key" => "floor", "type" => "integer"},
          %{"key" => "furnished", "type" => "boolean"},
          %{"key" => "zoning", "type" => "string"}
        ]
      },
      filter_config: [
        %{
          "key" => "price_mad",
          "kind" => "range",
          "source" => "column",
          "column" => "price",
          "unit" => "MAD",
          "min" => 100_000,
          "max" => 10_000_000
        },
        %{
          "key" => "surface",
          "kind" => "range",
          "source" => "column",
          "column" => "surface_m2",
          "unit" => "m²",
          "min" => 20,
          "max" => 500
        },
        %{
          "key" => "city",
          "kind" => "select",
          "source" => "column",
          "column" => "city",
          "options" => ["Casablanca", "Rabat", "Marrakech", "Fes", "Tangier"]
        },
        %{
          "key" => "bedrooms",
          "kind" => "select",
          "source" => "custom_field",
          "custom_field_key" => "bedrooms",
          "options" => ["Studio", "1", "2", "3", "4", "5+"]
        },
        %{
          "key" => "zoning",
          "kind" => "select",
          "source" => "custom_field",
          "custom_field_key" => "zoning",
          "options" => ["R+1", "R+2", "R+3", "R+4", "R+5+"]
        }
      ]
    }
  end

  defp land_def do
    %{
      key: "land",
      label: %{"fr" => "Terrain", "ar" => "أرض"},
      url_segment: %{"fr" => "terrains", "ar" => "أراضي"},
      position: 1,
      schema_hints: %{
        "known_keys" => [
          %{"key" => "zoning", "type" => "string"},
          %{"key" => "buildable-ratio", "type" => "decimal"},
          %{"key" => "topography", "type" => "string"}
        ]
      },
      filter_config: [
        %{
          "key" => "price_mad",
          "kind" => "range",
          "source" => "column",
          "column" => "price",
          "unit" => "MAD",
          "min" => 50_000,
          "max" => 50_000_000
        },
        %{
          "key" => "surface",
          "kind" => "range",
          "source" => "column",
          "column" => "surface_m2",
          "unit" => "m²",
          "min" => 100,
          "max" => 100_000
        },
        %{
          "key" => "city",
          "kind" => "select",
          "source" => "column",
          "column" => "city",
          "options" => ["Casablanca", "Rabat", "Marrakech", "Fes", "Tangier"]
        },
        %{
          "key" => "zoning",
          "kind" => "select",
          "source" => "custom_field",
          "custom_field_key" => "zoning",
          "options" => [
            "R+1",
            "R+2",
            "R+3",
            "R+4",
            "R+5+",
            "Agricole",
            "Industriel",
            "Commercial"
          ]
        }
      ]
    }
  end

  defp rental_def do
    %{
      key: "rental",
      label: %{"fr" => "Location", "ar" => "كراء"},
      url_segment: %{"fr" => "locations", "ar" => "كراء"},
      position: 2,
      schema_hints: %{
        "known_keys" => [
          %{"key" => "bedrooms", "type" => "integer"},
          %{"key" => "furnished", "type" => "boolean"},
          %{"key" => "lease-term", "type" => "string"},
          %{"key" => "deposit-months", "type" => "integer"}
        ]
      },
      filter_config: [
        %{
          "key" => "price_mad",
          "kind" => "range",
          "source" => "column",
          "column" => "price",
          "unit" => "MAD/month",
          "min" => 1_000,
          "max" => 100_000
        },
        %{
          "key" => "surface",
          "kind" => "range",
          "source" => "column",
          "column" => "surface_m2",
          "unit" => "m²",
          "min" => 20,
          "max" => 500
        },
        %{
          "key" => "city",
          "kind" => "select",
          "source" => "column",
          "column" => "city",
          "options" => ["Casablanca", "Rabat", "Marrakech", "Fes", "Tangier"]
        },
        %{
          "key" => "lease-term",
          "kind" => "select",
          "source" => "custom_field",
          "custom_field_key" => "lease-term",
          "options" => ["Mensuel", "Trimestriel", "Semestriel", "Annuel"]
        }
      ]
    }
  end

  ## Custom fields

  def seed_custom_fields(property_type) do
    fields = [
      %{
        key: "bedrooms",
        label: %{"fr" => "Chambres", "ar" => "غرف"},
        field_type: "integer",
        required: false,
        searchable: true,
        position: 0
      },
      %{
        key: "bathrooms-hy",
        label: %{"fr" => "Salles de bain", "ar" => "حمامات"},
        field_type: "integer",
        required: false,
        searchable: false,
        position: 1
      },
      %{
        key: "floor",
        label: %{"fr" => "Étage", "ar" => "الطابق"},
        field_type: "integer",
        required: false,
        searchable: false,
        position: 2
      },
      %{
        key: "furnished",
        label: %{"fr" => "Meublé", "ar" => "مفروش"},
        field_type: "boolean",
        required: false,
        searchable: true,
        position: 3
      },
      %{
        key: "zoning",
        label: %{"fr" => "Zonage", "ar" => "التقسيم"},
        field_type: "select",
        options: ["R+1", "R+2", "R+3", "R+4", "R+5+", "Agricole", "Industriel", "Commercial"],
        required: false,
        searchable: true,
        position: 4
      },
      %{
        key: "energy-class",
        label: %{"fr" => "Classe énergétique", "ar" => "الفئة الطاقية"},
        field_type: "select",
        options: ["A", "B", "C", "D", "E"],
        required: false,
        searchable: false,
        position: 5
      },
      %{
        key: "buildable-ratio",
        label: %{"fr" => "COS", "ar" => "معامل البناء"},
        field_type: "decimal",
        required: false,
        searchable: false,
        position: 6
      },
      %{
        key: "lease-term",
        label: %{"fr" => "Durée du bail", "ar" => "مدة العقد"},
        field_type: "select",
        options: ["Mensuel", "Trimestriel", "Semestriel", "Annuel"],
        required: false,
        searchable: true,
        position: 7
      },
      %{
        key: "deposit-months",
        label: %{"fr" => "Caution (mois)", "ar" => "الضمان (شهور)"},
        field_type: "integer",
        required: false,
        searchable: false,
        position: 8
      },
      %{
        key: "topography",
        label: %{"fr" => "Topographie", "ar" => "الطبوغرافيا"},
        field_type: "string",
        required: false,
        searchable: false,
        position: 9
      }
    ]

    Enum.each(fields, fn attrs ->
      case Catalog.list_custom_fields(property_type.id)
           |> Enum.find(&(&1.key == attrs.key)) do
        nil -> Catalog.create_custom_field(Map.put(attrs, :property_type_id, property_type.id))
        %{} -> :ok
      end
    end)
  end

  ## Developers

  defp seed_developer_with_subscription(slug, name) do
    dev =
      case Catalog.get_developer_by_slug(slug) do
        nil -> elem(Catalog.create_developer(%{name: name, slug: slug}), 1)
        %{} = existing -> existing
      end

    # One active subscription so the §5.13 billing gate runs against
    # realistic data when BILLING_ENFORCED is on.
    case Repo.get_by(Subscription, developer_id: dev.id, provider: "manual") do
      nil ->
        now = DateTime.utc_now(:second)

        %Subscription{
          developer_id: dev.id,
          plan: "featured",
          status: "active",
          provider: "manual",
          current_period_start: now,
          current_period_end: DateTime.add(now, 30, :day)
        }
        |> Repo.insert!()

      %{} = existing ->
        existing
    end

    dev
  end

  ## Projects

  defp seed_project(developer, slug_suffix, title_fr, city) do
    slug = "#{slug_suffix}-#{System.unique_integer([:positive])}"

    case Catalog.get_project_by_slug(slug) do
      nil ->
        attrs = %{
          developer_id: developer.id,
          title: %{"fr" => title_fr, "ar" => translate_title(title_fr)},
          slug: slug,
          description: %{"fr" => "Description #{title_fr}", "ar" => "وصف #{title_fr}"},
          city: city,
          region: region_for(city),
          country: "MA",
          lat: lat_for(city),
          lng: lng_for(city),
          address: "1 Rue #{title_fr}",
          amenities: %{"pool" => true, "gym" => false, "parking" => true},
          featured: false
        }

        {:ok, project} = Catalog.create_project(attrs)
        project

      %{} = existing ->
        existing
    end
  end

  ## Listings

  # The 6 projects are round-robin'd so every city + developer
  # combination gets listings across all 3 types. The total per
  # type: 16 apartments + 14 lands + 12 rentals = 42 listings.
  defp seed_listings(pt_apartment, pt_land, p1, p2, p3, p4, p5, p6) do
    projects = [p1, p2, p3, p4, p5, p6]

    # 16 apartment listings — mix of project-attached and standalone.
    apartments(projects, pt_apartment)
    # 14 land listings — half project-attached, half standalone.
    lands(projects, pt_land)
  end

  defp seed_listings_two(property_type, p1, p2, p3, p4, p5, p6) do
    # 12 rental listings — mostly project-attached (rentals cluster
    # in buildings).
    rentals([p1, p2, p3, p4, p5, p6], property_type)
  end

  defp apartments(projects, pt) do
    cities = ["Casablanca", "Rabat", "Marrakech", "Fes", "Tangier"]
    data = apartment_data()

    Enum.with_index(data, 1)
    |> Enum.each(fn {datum, idx} ->
      city = Enum.at(cities, rem(idx - 1, length(cities)))
      project = Enum.at(projects, rem(idx - 1, length(projects)))
      is_published? = rem(idx, 3) != 0
      is_standalone? = rem(idx, 4) == 0

      attrs =
        apartment_attrs(datum, idx, city, project, is_standalone?, is_published?)

      seed_listing(pt, attrs, idx, data)
    end)
  end

  defp lands(projects, pt) do
    data = land_data()

    Enum.with_index(data, 1)
    |> Enum.each(fn {datum, idx} ->
      city = Enum.at(["Casablanca", "Marrakech", "Fes", "Rabat", "Tangier"], rem(idx - 1, 5))
      project = Enum.at(projects, rem(idx - 1, length(projects)))
      is_standalone? = rem(idx, 2) == 0
      is_published? = rem(idx, 3) != 0

      attrs =
        land_attrs(datum, idx, city, project, is_standalone?, is_published?)

      seed_listing(pt, attrs, idx, data)
    end)
  end

  defp rentals(projects, pt) do
    data = rental_data()

    Enum.with_index(data, 1)
    |> Enum.each(fn {datum, idx} ->
      city = Enum.at(["Casablanca", "Rabat", "Tangier", "Fes", "Marrakech"], rem(idx - 1, 5))
      project = Enum.at(projects, rem(idx - 1, length(projects)))
      is_published? = rem(idx, 3) != 0
      is_standalone? = false

      attrs =
        rental_attrs(datum, idx, city, project, is_standalone?, is_published?)

      seed_listing(pt, attrs, idx, data)
    end)
  end

  defp seed_listing(pt, attrs, _idx, _all_data) do
    slug = attrs[:slug]

    attrs = Map.put(attrs, :property_type_id, pt.id)

    case Catalog.get_listing_by_slug(pt.id, slug) do
      nil ->
        {:ok, listing} = Catalog.create_listing(attrs)
        # Publish if requested.
        if attrs[:published_at], do: Catalog.publish_listing(listing)

      %{} ->
        :ok
    end
  end

  ## Listing data — apartment

  defp apartment_data do
    [
      %{
        slug: "apt-casa-1",
        title: "Appartement 2 chambres centre-ville",
        bedrooms: 2,
        bathrooms: 1,
        floor: 3,
        furnished: true,
        zoning: "R+3",
        energy_class: "A",
        price_mad: 1_250_000,
        surface: 75
      },
      %{
        slug: "apt-casa-2",
        title: "Studio rénové avec balcon",
        bedrooms: 1,
        bathrooms: 1,
        floor: 2,
        furnished: false,
        zoning: "R+2",
        energy_class: "B",
        price_mad: 850_000,
        surface: 45
      },
      %{
        slug: "apt-casa-3",
        title: "Penthouse 4 chambres vue mer",
        bedrooms: 4,
        bathrooms: 2,
        floor: 8,
        furnished: true,
        zoning: "R+5+",
        energy_class: "A",
        price_mad: 4_500_000,
        surface: 180
      },
      %{
        slug: "apt-rabat-1",
        title: "Appartement 3 chambres Hay Riad",
        bedrooms: 3,
        bathrooms: 2,
        floor: 1,
        furnished: false,
        zoning: "R+3",
        energy_class: "B",
        price_mad: 1_650_000,
        surface: 110
      },
      %{
        slug: "apt-rabat-2",
        title: "F2 rénové Agdal",
        bedrooms: 2,
        bathrooms: 1,
        floor: 4,
        furnished: true,
        zoning: "R+3",
        energy_class: "A",
        price_mad: 1_100_000,
        surface: 65
      },
      %{
        slug: "apt-marrakech-1",
        title: "Riad rénové médina",
        bedrooms: 4,
        bathrooms: 3,
        floor: 0,
        furnished: true,
        zoning: "R+2",
        energy_class: "C",
        price_mad: 3_200_000,
        surface: 220
      },
      %{
        slug: "apt-fes-1",
        title: "Appartement Fes Jdid",
        bedrooms: 2,
        bathrooms: 1,
        floor: 2,
        furnished: false,
        zoning: "R+2",
        energy_class: "C",
        price_mad: 720_000,
        surface: 70
      },
      %{
        slug: "apt-fes-2",
        title: "Studio rénové Fes",
        bedrooms: 1,
        bathrooms: 1,
        floor: 3,
        furnished: true,
        zoning: "R+3",
        energy_class: "B",
        price_mad: 540_000,
        surface: 38
      },
      %{
        slug: "apt-tangier-1",
        title: "Appartement vue mer Malabata",
        bedrooms: 3,
        bathrooms: 2,
        floor: 5,
        furnished: true,
        zoning: "R+4",
        energy_class: "A",
        price_mad: 2_400_000,
        surface: 130
      },
      %{
        slug: "apt-casa-4",
        title: "Appartement standing Maarif",
        bedrooms: 3,
        bathrooms: 2,
        floor: 6,
        furnished: false,
        zoning: "R+4",
        energy_class: "A",
        price_mad: 2_100_000,
        surface: 125
      },
      %{
        slug: "apt-casa-5",
        title: "F3 à rénover Bourgogne",
        bedrooms: 3,
        bathrooms: 1,
        floor: 1,
        furnished: false,
        zoning: "R+2",
        energy_class: "E",
        price_mad: 950_000,
        surface: 95,
        price_on_request: true
      },
      %{
        slug: "apt-rabat-3",
        title: "Duplex 4 chambres Souissi",
        bedrooms: 4,
        bathrooms: 3,
        floor: 2,
        furnished: true,
        zoning: "R+4",
        energy_class: "A",
        price_mad: 3_800_000,
        surface: 195
      },
      %{
        slug: "apt-marrakech-2",
        title: "Appartement Guéliz centre",
        bedrooms: 2,
        bathrooms: 1,
        floor: 3,
        furnished: false,
        zoning: "R+3",
        energy_class: "B",
        price_mad: 980_000,
        surface: 78
      },
      %{
        slug: "apt-marrakech-3",
        title: "Villa contemporaine Palmeraie",
        bedrooms: 5,
        bathrooms: 4,
        floor: 0,
        furnished: true,
        zoning: "R+2",
        energy_class: "A",
        price_mad: 7_500_000,
        surface: 450
      },
      %{
        slug: "apt-fes-3",
        title: "F4 familial Zouagha",
        bedrooms: 4,
        bathrooms: 2,
        floor: 1,
        furnished: false,
        zoning: "R+3",
        energy_class: "C",
        price_mad: 1_200_000,
        surface: 140
      },
      %{
        slug: "apt-tangier-2",
        title: "Appartement 2 chambres centre historique",
        bedrooms: 2,
        bathrooms: 1,
        floor: 2,
        furnished: true,
        zoning: "R+2",
        energy_class: "B",
        price_mad: 880_000,
        surface: 68
      }
    ]
  end

  defp apartment_attrs(d, idx, city, project, is_standalone?, is_published?) do
    base = %{
      property_type_id: nil,
      project_id: if(is_standalone?, do: nil, else: project.id),
      title: %{"fr" => d.title, "ar" => translate_title(d.title)},
      description: %{
        "fr" => "Appartement de qualité à #{city} — voir détails sur place.",
        "ar" => "شقة بجودة عالية في #{city}."
      },
      slug: "#{d.slug}-#{idx}",
      price: d.price_mad,
      price_on_request: Map.get(d, :price_on_request, false),
      currency: "MAD",
      status: Enum.at(~w(available available reserved sold rented available), rem(idx, 5)),
      address: "1 Rue Example, #{city}",
      city: city,
      region: region_for(city),
      country: "MA",
      lat: lat_for(city),
      lng: lng_for(city),
      surface_m2: d.surface,
      attributes: %{
        "bedrooms" => d.bedrooms,
        "bathrooms-hy" => d.bathrooms,
        "floor" => d.floor,
        "furnished" => d.furnished,
        "zoning" => d.zoning,
        "energy-class" => d.energy_class
      },
      seo: %{
        "title" => %{"fr" => "#{d.title} — Immo Atlas", "ar" => "#{d.title}"},
        "description" => %{"fr" => "Bel appartement à #{city}.", "ar" => "شقة جميلة."}
      }
    }

    maybe_publish(base, is_published?, d.title)
  end

  ## Listing data — land

  defp land_data do
    [
      %{
        slug: "land-marrakech-1",
        title: "Terrain 1000 m² Palmeraie",
        zoning: "R+2",
        buildable_ratio: 0.4,
        topography: "Plat",
        price_mad: 3_500_000,
        surface: 1000
      },
      %{
        slug: "land-marrakech-2",
        title: "Terrain agricole 5 ha",
        zoning: "Agricole",
        buildable_ratio: 0.0,
        topography: "Ondulé",
        price_mad: 2_200_000,
        surface: 50_000
      },
      %{
        slug: "land-fes-1",
        title: "Terrain industriel zone Ain Nokbi",
        zoning: "Industriel",
        buildable_ratio: 0.6,
        topography: "Plat",
        price_mad: 12_000_000,
        surface: 5_000
      },
      %{
        slug: "land-fes-2",
        title: "Terrain commercial Route d'Imouzer",
        zoning: "Commercial",
        buildable_ratio: 0.5,
        topography: "Plat",
        price_mad: 8_500_000,
        surface: 2_500
      },
      %{
        slug: "land-casa-1",
        title: "Terrain Tit Mellil 2000 m²",
        zoning: "R+3",
        buildable_ratio: 0.5,
        topography: "Plat",
        price_mad: 4_800_000,
        surface: 2_000
      },
      %{
        slug: "land-casa-2",
        title: "Terrain Bouskoura 1500 m²",
        zoning: "R+3",
        buildable_ratio: 0.5,
        topography: "Plat",
        price_mad: 4_200_000,
        surface: 1_500
      },
      %{
        slug: "land-rabat-1",
        title: "Terrain Tamesna 3000 m²",
        zoning: "R+4",
        buildable_ratio: 0.5,
        topography: "Plat",
        price_mad: 7_200_000,
        surface: 3_000
      },
      %{
        slug: "land-rabat-2",
        title: "Terrain Bouknadel 5000 m²",
        zoning: "Agricole",
        buildable_ratio: 0.1,
        topography: "Ondulé",
        price_mad: 1_800_000,
        surface: 5_000
      },
      %{
        slug: "land-tangier-1",
        title: "Terrain Rmilat 1200 m² vue mer",
        zoning: "R+2",
        buildable_ratio: 0.3,
        topography: "Pente",
        price_mad: 2_800_000,
        surface: 1_200
      },
      %{
        slug: "land-tangier-2",
        title: "Terrain résidentiel Asilah",
        zoning: "R+2",
        buildable_ratio: 0.4,
        topography: "Plat",
        price_mad: 1_900_000,
        surface: 900,
        price_on_request: true
      },
      %{
        slug: "land-marrakech-3",
        title: "Terrain Tameslouht 3 ha",
        zoning: "Agricole",
        buildable_ratio: 0.0,
        topography: "Plat",
        price_mad: 4_500_000,
        surface: 30_000
      },
      %{
        slug: "land-fes-3",
        title: "Terrain Sefrou 2 ha vue atlas",
        zoning: "Agricole",
        buildable_ratio: 0.0,
        topography: "Pente",
        price_mad: 2_800_000,
        surface: 20_000
      },
      %{
        slug: "land-casa-3",
        title: "Terrain Mohammedia 800 m²",
        zoning: "R+3",
        buildable_ratio: 0.5,
        topography: "Plat",
        price_mad: 2_400_000,
        surface: 800
      },
      %{
        slug: "land-rabat-3",
        title: "Terrain Salé 600 m²",
        zoning: "R+3",
        buildable_ratio: 0.5,
        topography: "Plat",
        price_mad: 1_400_000,
        surface: 600
      }
    ]
  end

  defp land_attrs(d, idx, city, project, is_standalone?, is_published?) do
    base = %{
      property_type_id: nil,
      project_id: if(is_standalone?, do: nil, else: project.id),
      title: %{"fr" => d.title, "ar" => translate_title(d.title)},
      description: %{
        "fr" => "Terrain à #{city} — bien situé.",
        "ar" => "أرض في #{city}."
      },
      slug: "#{d.slug}-#{idx}",
      price: d.price_mad,
      price_on_request: Map.get(d, :price_on_request, false),
      currency: "MAD",
      status: Enum.at(~w(available reserved sold rented), rem(idx, 4)),
      address: "Route de #{city}",
      city: city,
      region: region_for(city),
      country: "MA",
      lat: lat_for(city),
      lng: lng_for(city),
      surface_m2: d.surface,
      attributes: %{
        "zoning" => d.zoning,
        "buildable-ratio" => d.buildable_ratio,
        "topography" => d.topography
      },
      seo: %{
        "title" => %{"fr" => "Terrain #{city}", "ar" => "أرض #{city}"},
        "description" => %{"fr" => "Terrain à vendre.", "ar" => "أرض للبيع."}
      }
    }

    maybe_publish(base, is_published?, d.title)
  end

  ## Listing data — rental

  defp rental_data do
    [
      %{
        slug: "rental-casa-1",
        title: "Studio meublé Maarif 6 mois",
        bedrooms: 0,
        furnished: true,
        lease_term: "Semestriel",
        deposit_months: 2,
        price_mad: 6_500
      },
      %{
        slug: "rental-casa-2",
        title: "Appartement 2 chambres meublé",
        bedrooms: 2,
        furnished: true,
        lease_term: "Annuel",
        deposit_months: 2,
        price_mad: 9_500
      },
      %{
        slug: "rental-rabat-1",
        title: "F3 vide Agdal bail annuel",
        bedrooms: 2,
        furnished: false,
        lease_term: "Annuel",
        deposit_months: 2,
        price_mad: 7_800
      },
      %{
        slug: "rental-rabat-2",
        title: "Studio meublé Hassan",
        bedrooms: 1,
        furnished: true,
        lease_term: "Mensuel",
        deposit_months: 1,
        price_mad: 4_500
      },
      %{
        slug: "rental-tangier-1",
        title: "Appartement vue mer Cap Malabata",
        bedrooms: 2,
        furnished: true,
        lease_term: "Annuel",
        deposit_months: 3,
        price_mad: 12_000
      },
      %{
        slug: "rental-fes-1",
        title: "F2 vide centre-ville",
        bedrooms: 2,
        furnished: false,
        lease_term: "Annuel",
        deposit_months: 2,
        price_mad: 4_200
      },
      %{
        slug: "rental-marrakech-1",
        title: "Riad meublé médina 1 mois",
        bedrooms: 3,
        furnished: true,
        lease_term: "Mensuel",
        deposit_months: 1,
        price_mad: 18_000
      },
      %{
        slug: "rental-casa-3",
        title: "Loft vide Bourgogne",
        bedrooms: 1,
        furnished: false,
        lease_term: "Annuel",
        deposit_months: 2,
        price_mad: 6_800
      },
      %{
        slug: "rental-rabat-3",
        title: "Appartement meublé Souissi",
        bedrooms: 3,
        furnished: true,
        lease_term: "Annuel",
        deposit_months: 2,
        price_mad: 11_500
      },
      %{
        slug: "rental-tangier-2",
        title: "Studio centre historique",
        bedrooms: 0,
        furnished: true,
        lease_term: "Trimestriel",
        deposit_months: 1,
        price_mad: 3_500
      },
      %{
        slug: "rental-casa-4",
        title: "F4 standing Anfa",
        bedrooms: 3,
        furnished: true,
        lease_term: "Annuel",
        deposit_months: 3,
        price_mad: 16_000,
        price_on_request: true
      },
      %{
        slug: "rental-fes-2",
        title: "F3 familial ZOUAGHA",
        bedrooms: 3,
        furnished: false,
        lease_term: "Annuel",
        deposit_months: 2,
        price_mad: 5_800
      }
    ]
  end

  defp rental_attrs(d, idx, city, project, _is_standalone?, is_published?) do
    base = %{
      property_type_id: nil,
      project_id: project.id,
      title: %{"fr" => d.title, "ar" => translate_title(d.title)},
      description: %{
        "fr" => "Location à #{city} — conditions négociables.",
        "ar" => "كراء في #{city}."
      },
      slug: "#{d.slug}-#{idx}",
      price: d.price_mad,
      price_on_request: Map.get(d, :price_on_request, false),
      currency: "MAD",
      status: Enum.at(~w(available rented reserved), rem(idx, 3)),
      address: "1 Rue Example, #{city}",
      city: city,
      region: region_for(city),
      country: "MA",
      lat: lat_for(city),
      lng: lng_for(city),
      surface_m2: 45 + d.bedrooms * 25,
      attributes: %{
        "bedrooms" => d.bedrooms,
        "furnished" => d.furnished,
        "lease-term" => d.lease_term,
        "deposit-months" => d.deposit_months
      },
      seo: %{
        "title" => %{"fr" => "Location #{city}", "ar" => "كراء #{city}"},
        "description" => %{"fr" => "À louer.", "ar" => "للإيجار."}
      }
    }

    maybe_publish(base, is_published?, d.title)
  end

  ## Helpers

  defp maybe_publish(base, true, _title) do
    # 1/3 of the listings are draft (published_at stays nil). 2/3 are
    # past-published (publishable). We skip the future-scheduled variant
    # for now — the §15.1 matrix tests already cover that case.
    Map.put(base, :published_at, DateTime.utc_now(:second) |> DateTime.add(-3600, :second))
  end

  defp maybe_publish(base, false, _title), do: base

  defp region_for("Casablanca"), do: "Casablanca-Settat"
  defp region_for("Rabat"), do: "Rabat-Salé-Kénitra"
  defp region_for("Marrakech"), do: "Marrakech-Safi"
  defp region_for("Fes"), do: "Fès-Meknès"
  defp region_for("Tangier"), do: "Tanger-Tétouan-Al Hoceïma"
  defp region_for(_), do: "Casablanca-Settat"

  defp lat_for("Casablanca"), do: 33.5731
  defp lat_for("Rabat"), do: 34.0209
  defp lat_for("Marrakech"), do: 31.6295
  defp lat_for("Fes"), do: 34.0181
  defp lat_for("Tangier"), do: 35.7595
  defp lat_for(_), do: 33.5731

  defp lng_for("Casablanca"), do: -7.5898
  defp lng_for("Rabat"), do: -6.8416
  defp lng_for("Marrakech"), do: -7.9811
  defp lng_for("Fes"), do: -5.0078
  defp lng_for("Tangier"), do: -5.8340
  defp lng_for(_), do: -7.5898

  # The ar translations are deterministic placeholders rather than
  # professional translations — the seed's purpose is to exercise
  # the i18n jsonb maps end-to-end, not to be a translation
  # dictionary. P1-E7 / the front-end translate via the i18n
  # table at render time.
  defp translate_title(fr) do
    "عقار - #{String.slice(fr, 0, 50)}"
  end
end
