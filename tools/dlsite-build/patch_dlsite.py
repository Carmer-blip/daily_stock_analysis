import pathlib
import re
import sys

src = pathlib.Path("source/DLsiteScrapper.cs")
text = src.read_text(encoding="utf-8-sig")

old = '''        var productIdMatch = Regex.Match(url, @"product_id/([A-Z]{2}\\d+)");
        var productId = productIdMatch.Success ? productIdMatch.Groups[1].Value : null;'''
new = '''        var productIdMatch = Regex.Match(url, @"product_id/([A-Z]{2}\\d+)", RegexOptions.IgnoreCase);
        var productId = productIdMatch.Success ? productIdMatch.Groups[1].Value.ToUpperInvariant() : null;
        var siteMatch = Regex.Match(url, @"https?://www\\.dlsite\\.com/([^/]+)/work/", RegexOptions.IgnoreCase);
        var site = siteMatch.Success ? siteMatch.Groups[1].Value.ToLowerInvariant() : "home";'''
if old not in text:
    raise SystemExit("Could not find productId extraction block; source version mismatch.")
text = text.replace(old, new, 1)

text = text.replace(
    'var (jsonRating, jsonTitle) = await FetchJsonInfoAsync(productId, language);',
    'var (jsonRating, jsonTitle) = await FetchJsonInfoAsync(productId, site, language);',
    1
)

old_desc = '''        var descriptionHtml = document.QuerySelector("[itemprop='description']")?.InnerHtml;
        var description = descriptionHtml?.Replace("//img.dlsite.jp", "https://img.dlsite.jp");
        result.Description = Regex.Replace(description?.Trim(), @"^\\s*$\\n|\\r", string.Empty, RegexOptions.Multiline);

        return result;'''
new_desc = '''        var descriptionHtml = document.QuerySelector("[itemprop='description']")?.InnerHtml;
        if (string.IsNullOrWhiteSpace(descriptionHtml))
        {
            var workParts = document.QuerySelectorAll(".work_parts")
                .Select(x => x.InnerHtml)
                .Where(x => !string.IsNullOrWhiteSpace(x))
                .ToList();
            if (workParts.Count > 0)
                descriptionHtml = string.Join(Environment.NewLine, workParts);
        }

        if (string.IsNullOrWhiteSpace(descriptionHtml))
            descriptionHtml = document.QuerySelector(".work_intro")?.InnerHtml;

        var description = descriptionHtml?.Replace("//img.dlsite.jp", "https://img.dlsite.jp");
        result.Description = string.IsNullOrWhiteSpace(description)
            ? null
            : Regex.Replace(description.Trim(), @"^\\s*$\\n|\\r", string.Empty, RegexOptions.Multiline);

        // The current DLsite product.json API is the authoritative source for metadata.
        // Keep the HTML parser as a fallback, then fill missing fields from structured data.
        if (!string.IsNullOrEmpty(productId))
            await FetchStructuredProductDataAsync(result, productId, site, language, categoryMappingTarget);

        return result;'''
if old_desc not in text:
    raise SystemExit("Could not find description/return block; source version mismatch.")
text = text.replace(old_desc, new_desc, 1)

start = text.find('    /// Fetches work_name and rating from DLsite\\'s JSON API')
end = text.find('    private static List<string> ParseImages(IDocument document)', start)
if start < 0 or end < 0:
    raise SystemExit("Could not locate JSON helper section.")
new_helpers = r'''    /// <summary>
    /// Reads DLsite's legacy info endpoint. Newer responses can be arrays or objects,
    /// so never assume the response is a JObject keyed by product ID.
    /// </summary>
    private async Task<(double? Rating, string WorkName)> FetchJsonInfoAsync(
        string productId, string site, SupportedLanguages language)
    {
        try
        {
            var handler = CreateDlsiteHandler(language);
            using var client = new HttpClient(handler);
            client.Timeout = TimeSpan.FromSeconds(25);

            var url = $"https://www.dlsite.com/{site}/product/info/ajax?product_id={productId}&cdn_cache_min=1";
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            AddDlsiteHeaders(request, site, productId);

            var response = await client.SendAsync(request);
            response.EnsureSuccessStatusCode();
            var json = await response.Content.ReadAsStringAsync();
            var productNode = ExtractProductObject(json, productId);

            if (productNode == null)
            {
                logger.Warn($"DLsite info API returned no product object for {productId} (site={site}).");
                return (null, null);
            }

            var rating = GetNumber(productNode["rate_average_2dp"])
                         ?? GetNumber(productNode["rate_average"])
                         ?? GetNumber(productNode["rating"]);

            if (!rating.HasValue)
            {
                var starRating = GetNumber(productNode["rate_average_star"]);
                if (starRating.HasValue) rating = starRating.Value / 10.0;
            }

            return (rating, FirstString(productNode, "work_name", "product_name", "work_name_masked"));
        }
        catch (Exception ex)
        {
            logger.Warn(ex, $"Failed to fetch DLsite info JSON for {productId}");
            return (null, null);
        }
    }

    private async Task FetchStructuredProductDataAsync(
        DLsiteScrapperResult result,
        string productId,
        string site,
        SupportedLanguages language,
        string categoryMappingTarget)
    {
        var candidates = new List<string>();
        void AddSite(string value)
        {
            if (!string.IsNullOrWhiteSpace(value) && !candidates.Contains(value))
                candidates.Add(value);
        }

        AddSite(site);
        if (productId.StartsWith("VJ", StringComparison.OrdinalIgnoreCase))
        {
            AddSite("pro");
            AddSite("soft");
        }
        else if (productId.StartsWith("RJ", StringComparison.OrdinalIgnoreCase))
        {
            AddSite("maniax");
            AddSite("home");
        }
        else
        {
            AddSite("home");
            AddSite("maniax");
            AddSite("pro");
        }

        foreach (var candidate in candidates)
        {
            try
            {
                var handler = CreateDlsiteHandler(language);
                using var client = new HttpClient(handler);
                client.Timeout = TimeSpan.FromSeconds(25);

                var apiUrl = $"https://www.dlsite.com/{candidate}/api/=/product.json?workno={Uri.EscapeDataString(productId)}";
                using var request = new HttpRequestMessage(HttpMethod.Get, apiUrl);
                AddDlsiteHeaders(request, candidate, productId);

                var response = await client.SendAsync(request);
                if (!response.IsSuccessStatusCode)
                {
                    logger.Warn($"DLsite product.json returned HTTP {(int)response.StatusCode} for {productId} (site={candidate}).");
                    continue;
                }

                var json = await response.Content.ReadAsStringAsync();
                var product = ExtractProductObject(json, productId);
                if (product == null)
                {
                    logger.Warn($"DLsite product.json did not contain a product object for {productId} (site={candidate}).");
                    continue;
                }

                ApplyStructuredProductData(result, product, categoryMappingTarget);
                logger.Info($"Loaded structured DLsite metadata for {productId} (site={candidate}).");
                return;
            }
            catch (Exception ex)
            {
                logger.Warn(ex, $"Failed to fetch DLsite product.json for {productId} (site={candidate}).");
            }
        }
    }

    private static HttpClientHandler CreateDlsiteHandler(SupportedLanguages language)
    {
        var handler = new HttpClientHandler
        {
            UseCookies = true,
            CookieContainer = new CookieContainer(),
            UseProxy = true
        };
        var baseUri = new Uri("https://www.dlsite.com/");
        handler.CookieContainer.Add(baseUri, new Cookie("locale", language.ToString(), "/", ".dlsite.com"));
        handler.CookieContainer.Add(baseUri, new Cookie("loginchecked", "1", "/", ".dlsite.com"));
        handler.CookieContainer.Add(baseUri, new Cookie("adultchecked", "1", "/", ".dlsite.com"));
        return handler;
    }

    private static void AddDlsiteHeaders(HttpRequestMessage request, string site, string productId)
    {
        request.Headers.UserAgent.ParseAdd(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36");
        request.Headers.Accept.ParseAdd("application/json, text/javascript, */*; q=0.01");
        request.Headers.Referrer = new Uri($"https://www.dlsite.com/{site}/work/=/product_id/{productId}.html");
        request.Headers.Add("X-Requested-With", "XMLHttpRequest");
    }

    private static JObject ExtractProductObject(string json, string productId)
    {
        if (string.IsNullOrWhiteSpace(json))
            return null;

        try
        {
            var root = JToken.Parse(json);
            if (root is JArray array)
            {
                var match = array.OfType<JObject>().FirstOrDefault(item =>
                    string.Equals(FirstString(item, "workno", "product_id", "base_product_id"),
                        productId, StringComparison.OrdinalIgnoreCase));
                return match ?? array.OfType<JObject>().FirstOrDefault();
            }

            if (root is JObject obj)
            {
                if (obj[productId] is JObject keyedProduct)
                    return keyedProduct;

                if (obj["data"] is JArray dataArray)
                    return dataArray.OfType<JObject>().FirstOrDefault();

                if (obj["data"] is JObject dataObject)
                    return dataObject;

                if (obj["product"] is JObject productObject)
                    return productObject;

                return obj;
            }
        }
        catch (Exception)
        {
            return null;
        }

        return null;
    }

    private static void ApplyStructuredProductData(
        DLsiteScrapperResult result, JObject product, string categoryMappingTarget)
    {
        result.Title ??= FirstString(product, "work_name", "product_name", "work_name_masked", "alt_name");
        result.Circle ??= FirstString(product, "maker_name", "brand_name", "circle_name");
        result.Series ??= FirstString(product, "series_name", "title_name");
        result.UpdateDate ??= FirstString(product, "update_date", "modify_date");
        result.Filesize ??= FirstString(product, "file_size_unit", "file_size", "filesize");

        if (!result.ReleaseDate.HasValue)
        {
            var dateText = FirstString(product, "regist_date", "release_date", "sales_date");
            if (DateTime.TryParse(dateText, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var releaseDate))
                result.ReleaseDate = releaseDate;
        }

        if (!result.Age.HasValue)
        {
            var age = FirstString(product, "age_category_string", "age_category", "age_rating");
            if (!string.IsNullOrWhiteSpace(age))
            {
                var normalized = age.Trim().ToLowerInvariant();
                if (normalized.Contains("general") || normalized.Contains("全年齢") || normalized == "1")
                    result.Age = DLsiteScrapperResult.AgeRating.AllAges;
                else if (normalized.Contains("r15") || normalized.Contains("15"))
                    result.Age = DLsiteScrapperResult.AgeRating.RRated;
                else if (normalized.Contains("adult") || normalized.Contains("18") || normalized.Contains("成年"))
                    result.Age = DLsiteScrapperResult.AgeRating.Adult;
            }
        }

        var creators = product["creaters"] as JObject ?? product["creators"] as JObject;
        result.Author = MergeNames(result.Author,
            GetNames(creators?["created_by"] ?? product["created_by"] ?? product["author"]));
        result.ScenarioWriters = MergeNames(result.ScenarioWriters,
            GetNames(creators?["scenario_by"] ?? product["scenario_by"]));
        result.Illustrators = MergeNames(result.Illustrators,
            GetNames(creators?["illust_by"] ?? product["illust_by"] ?? product["illustrator"]));
        result.VoiceActors = MergeNames(result.VoiceActors,
            GetNames(creators?["voice_by"] ?? product["voice_by"]));
        result.MusicCreators = MergeNames(result.MusicCreators,
            GetNames(creators?["music_by"] ?? product["music_by"]));

        var genres = GetNames(product["genres_replaced"] ?? product["genres"]);
        if (genres.Count > 0)
        {
            if (string.Equals(categoryMappingTarget, "Tags", StringComparison.OrdinalIgnoreCase))
                result.Tags = MergeNames(result.Tags, genres);
            else
                result.Genres = MergeNames(result.Genres, genres);
        }

        result.FileFormat = MergeNames(result.FileFormat,
            GetNames(product["file_type_string"] ?? product["file_type"]));
        result.ProductFormat = MergeNames(result.ProductFormat,
            GetNames(product["work_type_string"]));
        result.Miscellaneous = MergeNames(result.Miscellaneous,
            GetNames(product["work_type_special"] ?? product["etc"]));

        var rating = GetNumber(product["rate_average_2dp"])
                     ?? GetNumber(product["rate_average"])
                     ?? GetNumber(product["rating"]);
        if (!rating.HasValue)
        {
            var starRating = GetNumber(product["rate_average_star"]);
            if (starRating.HasValue) rating = starRating.Value / 10.0;
        }
        if (!result.Rating.HasValue && rating.HasValue)
            result.Rating = (float)rating.Value;

        var mainImage = GetImageUrl(product["image_main"]) ?? GetImageUrl(product["work_image"]);
        result.MainImage ??= mainImage;
        result.Icon ??= GetImageUrl(product["image_thum_mini"])
                        ?? GetImageUrl(product["image_thum"])
                        ?? result.MainImage?.Replace("_img_main", "_img_sam_mini");

        var productImages = ExtractProductImages(product);
        if (!string.IsNullOrWhiteSpace(result.MainImage))
            productImages.Insert(0, result.MainImage);
        result.ProductImages = MergeNames(result.ProductImages, productImages);

        if (string.IsNullOrWhiteSpace(result.Description))
        {
            var intro = FirstString(product, "intro", "intro_s", "intro_masked", "description");
            if (string.IsNullOrWhiteSpace(intro) && product["introductions"] is JArray introductions)
                intro = string.Join(Environment.NewLine,
                    introductions.Select(x => x.Type == JTokenType.String ? x.ToString() :
                        FirstString(x as JObject, "text", "intro", "description"))
                    .Where(x => !string.IsNullOrWhiteSpace(x)));

            if (!string.IsNullOrWhiteSpace(intro))
                result.Description = intro.Replace("\\/\\/", "//").Replace("//img.dlsite.jp", "https://img.dlsite.jp");
        }
    }

    private static List<string> ExtractProductImages(JObject product)
    {
        var images = new List<string>();
        foreach (var key in new[] { "image_samples", "samples", "sample_images", "sample_image", "images" })
        {
            var token = product[key];
            if (token == null || token.Type == JTokenType.Null)
                continue;

            if (token.Type == JTokenType.String)
            {
                var raw = token.ToString();
                if (raw.TrimStart().StartsWith("[", StringComparison.Ordinal))
                {
                    try { token = JToken.Parse(raw); }
                    catch { continue; }
                }
                else
                {
                    var url = NormalizeImageUrl(raw);
                    if (!string.IsNullOrWhiteSpace(url)) images.Add(url);
                    continue;
                }
            }

            if (token is JArray array)
            {
                foreach (var item in array)
                {
                    var url = GetImageUrl(item);
                    if (!string.IsNullOrWhiteSpace(url)) images.Add(url);
                }
            }
            else
            {
                var url = GetImageUrl(token);
                if (!string.IsNullOrWhiteSpace(url)) images.Add(url);
            }
        }

        return images.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static string GetImageUrl(JToken token)
    {
        if (token == null || token.Type == JTokenType.Null)
            return null;

        if (token.Type == JTokenType.String)
            return NormalizeImageUrl(token.ToString());

        if (token is JObject obj)
        {
            foreach (var key in new[] { "url", "thumb", "src", "image_url", "image", "relative_url", "path" })
            {
                var value = obj[key]?.ToString();
                var normalized = NormalizeImageUrl(value);
                if (!string.IsNullOrWhiteSpace(normalized))
                    return normalized;
            }
        }

        return null;
    }

    private static string NormalizeImageUrl(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;

        value = value.Trim().Replace("\\/", "/");
        if (value.StartsWith("//", StringComparison.Ordinal))
            value = "https:" + value;
        else if (value.StartsWith("/", StringComparison.Ordinal))
            value = "https://www.dlsite.com" + value;

        return value.Contains("img.dlsite.jp", StringComparison.OrdinalIgnoreCase)
            ? value
            : null;
    }

    private static List<string> GetNames(JToken token)
    {
        var names = new List<string>();
        if (token == null || token.Type == JTokenType.Null)
            return names;

        if (token.Type == JTokenType.String)
        {
            var value = token.ToString().Trim();
            if (!string.IsNullOrWhiteSpace(value)) names.Add(value);
            return names;
        }

        if (token is JArray array)
        {
            foreach (var item in array)
                names.AddRange(GetNames(item));
            return names.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        }

        if (token is JObject obj)
        {
            var name = FirstString(obj, "name", "label", "text", "work_name");
            if (!string.IsNullOrWhiteSpace(name))
                names.Add(name.Trim());
        }

        return names.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static List<string> MergeNames(List<string> existing, IEnumerable<string> additions)
    {
        var merged = existing == null ? new List<string>() : new List<string>(existing);
        if (additions != null)
        {
            foreach (var item in additions)
            {
                if (!string.IsNullOrWhiteSpace(item) &&
                    !merged.Any(x => string.Equals(x, item, StringComparison.OrdinalIgnoreCase)))
                    merged.Add(item.Trim());
            }
        }
        return merged.Count == 0 ? null : merged;
    }

    private static string FirstString(JObject obj, params string[] keys)
    {
        if (obj == null) return null;
        foreach (var key in keys)
        {
            var value = obj[key];
            if (value == null || value.Type == JTokenType.Null) continue;
            if (value.Type == JTokenType.String || value.Type == JTokenType.Integer ||
                value.Type == JTokenType.Float || value.Type == JTokenType.Boolean)
            {
                var text = value.ToString().Trim();
                if (!string.IsNullOrWhiteSpace(text)) return text;
            }
        }
        return null;
    }

    private static double? GetNumber(JToken token)
    {
        if (token == null || token.Type == JTokenType.Null) return null;
        if (double.TryParse(token.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var value))
            return value;
        return null;
    }

'''
text = text[:start] + new_helpers + text[end:]

# Replace the old image parser with a selector-tolerant implementation.
start = text.find('    private static List<string> ParseImages(IDocument document)')
if start < 0:
    raise SystemExit("Could not locate ParseImages.")
# ParseImages is the final method before the class closing brace.
end = text.rfind('\n}')
if end < start:
    raise SystemExit("Could not locate class end.")
new_parser = r'''    private static List<string> ParseImages(IDocument document)
    {
        var images = new List<string>();
        var selectors = new[]
        {
            "#work_left .product-slider-data [data-src]",
            "#work_left .product-slider-data img",
            ".product-slider-data [data-src]",
            ".product-slider-data img",
            "#work_left img[src*='img.dlsite.jp']",
            ".work_parts img[src*='img.dlsite.jp']",
            "[class*='sample'] img",
            "[class*='slider'] img"
        };

        foreach (var selector in selectors)
        {
            IEnumerable<IElement> elements;
            try { elements = document.QuerySelectorAll(selector); }
            catch { continue; }

            foreach (var element in elements)
            {
                foreach (var attribute in new[] { "data-src", "data-original", "data-lazy", "src" })
                {
                    var url = NormalizeImageUrl(element.GetAttribute(attribute));
                    if (!string.IsNullOrWhiteSpace(url) &&
                        !images.Contains(url, StringComparer.OrdinalIgnoreCase))
                        images.Add(url);
                }

                var srcset = element.GetAttribute("srcset");
                if (!string.IsNullOrWhiteSpace(srcset))
                {
                    var first = srcset.Split(',').Select(x => x.Trim().Split(' ').FirstOrDefault())
                        .FirstOrDefault(x => !string.IsNullOrWhiteSpace(x));
                    var url = NormalizeImageUrl(first);
                    if (!string.IsNullOrWhiteSpace(url) &&
                        !images.Contains(url, StringComparer.OrdinalIgnoreCase))
                        images.Add(url);
                }
            }
        }

        return images;
    }
'''
text = text[:start] + new_parser + text[end:]

src.write_text(text, encoding="utf-8-sig", newline="")
print("Patched", src)
