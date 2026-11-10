$ErrorActionPreference = "Stop"

function Replace-Once {
    param(
        [string]$Source,
        [string]$Pattern,
        [string]$Replacement,
        [string]$Label
    )
    $rx = [regex]::new($Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($rx.Matches($Source).Count -ne 1) {
        throw "Could not safely locate exactly one source block: $Label"
    }
    return $rx.Replace($Source, $Replacement.Replace('$', '$$'), 1)
}

$sourcePath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\DLsiteScrapper.cs"
$providerPath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\DLsiteMetadataProvider.cs"
$manifestPath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\extension.yaml"

$code = [IO.File]::ReadAllText($sourcePath)

if ($code -notmatch "using System\.IO;") {
    $code = $code.Replace("using System.Globalization;", "using System.Globalization;" + [Environment]::NewLine + "using System.IO;")
}
if ($code -notmatch "using System\.Text;") {
    $code = $code.Replace("using System.Net.Http;", "using System.Net.Http;" + [Environment]::NewLine + "using System.Text;")
}

# Replace only the transport layer. The original HTML metadata extraction remains untouched.
$pagePattern = '(?s)        HttpResponseMessage res;.*?        var responseBody = await res\.Content\.ReadAsStringAsync\(\);\s*'
$pageReplacement = @'
        var (responseBody, finalUrl) = await DownloadStringAsync(
            url,
            language,
            BuildWorkPageReferer(url, language),
            false
        );
        result.Links.Add("DLsite", finalUrl); // for redirects

'@
$code = Replace-Once $code $pagePattern $pageReplacement "product page request"

# Keep the original search URL and search-result selectors; only route its HTTP request through the same compatible transport.
$searchRequestPattern = '(?s)        var handler = new HttpClientHandler \{ UseCookies = true, CookieContainer = new CookieContainer\(\) \};\s*var baseUri = new Uri\(SiteBaseUrl\);.*?        var responseBody = await client\.GetStringAsync\(SiteBaseUrl \+ searchUrl\);\s*'
$searchRequestReplacement = @'
        var (responseBody, _) = await DownloadStringAsync(
            SiteBaseUrl + searchUrl,
            language,
            SiteBaseUrl,
            false
        );

'@
$code = Replace-Once $code $searchRequestPattern $searchRequestReplacement "search page request"

# Use the product's actual catalogue category for the JSON rating/title endpoint.
$oldJsonCall = "FetchJsonInfoAsync(productId, language)"
if (-not $code.Contains($oldJsonCall)) { throw "Could not locate original JSON metadata call." }
$code = $code.Replace($oldJsonCall, "FetchJsonInfoAsync(productId, language, GetCategoryFromUrl(url))")

# Replace only the JSON enrichment routine. All original HTML field parsing and ParseImages stay as authored upstream.
$jsonPattern = '(?s)    /// Fetches work_name and rating from DLsite.*?    private static List<string> ParseImages'
$jsonReplacement = @'
    /// Fetches work_name and rating from DLsite's category-specific JSON API.
    /// The upstream HTML scraper remains the source for all other metadata fields.
    private async Task<(double? Rating, string WorkName)> FetchJsonInfoAsync(
        string productId,
        SupportedLanguages language,
        string category)
    {
        try
        {
            var apiUrl = $"https://www.dlsite.com/{category}/product/info/ajax?product_id={productId}&cdn_cache_min=1";
            var referer = $"https://www.dlsite.com/{category}/work/=/product_id/{productId}.html?locale={language}";
            var (json, _) = await DownloadStringAsync(apiUrl, language, referer, true);

            var root = JToken.Parse(json);
            var productNode = FindProductObject(root, productId, true)
                              ?? FindProductObject(root, productId, false);

            if (productNode == null)
            {
                var preview = json.Substring(0, Math.Min(json.Length, 500));
                logger.Warn($"DLsite JSON response did not contain a product object for {productId}. Root type: {root.Type}. Preview: {preview}");
                return (null, null);
            }

            double parsedRating;
            double? rating = double.TryParse(
                productNode["rate_average_2dp"]?.ToString(),
                NumberStyles.Any,
                CultureInfo.InvariantCulture,
                out parsedRating)
                ? parsedRating
                : (double?)null;

            return (rating, productNode["work_name"]?.ToString());
        }
        catch (Exception ex)
        {
            logger.Warn(ex, $"Failed to fetch JSON data for {productId}");
            return (null, null);
        }
    }

    private static JObject FindProductObject(JToken token, string productId, bool requireMatchingId)
    {
        if (token is JObject obj)
        {
            var direct = obj[productId];
            if (direct is JObject directObject)
                return directObject;
            if (direct is JArray directArray)
            {
                var directArrayObject = directArray.OfType<JObject>().FirstOrDefault();
                if (directArrayObject != null)
                    return directArrayObject;
            }

            var idToken = obj["product_id"]
                          ?? obj["productId"]
                          ?? obj["workno"]
                          ?? obj["work_no"]
                          ?? obj["work_id"]
                          ?? obj["id"];

            if (idToken != null &&
                string.Equals(idToken.ToString(), productId, StringComparison.OrdinalIgnoreCase))
                return obj;

            foreach (var property in obj.Properties())
            {
                if (string.Equals(property.Name, productId, StringComparison.OrdinalIgnoreCase))
                {
                    if (property.Value is JObject propertyObject)
                        return propertyObject;
                    if (property.Value is JArray propertyArray)
                    {
                        var propertyArrayObject = propertyArray.OfType<JObject>().FirstOrDefault();
                        if (propertyArrayObject != null)
                            return propertyArrayObject;
                    }
                }
            }

            foreach (var property in obj.Properties())
            {
                var nested = FindProductObject(property.Value, productId, requireMatchingId);
                if (nested != null)
                    return nested;
            }

            if (!requireMatchingId &&
                (obj["work_name"] != null || obj["rate_average_2dp"] != null))
                return obj;
        }
        else if (token is JArray array)
        {
            foreach (var item in array)
            {
                var nested = FindProductObject(item, productId, requireMatchingId);
                if (nested != null)
                    return nested;
            }
        }

        return null;
    }

    private static string GetCategoryFromUrl(string url)
    {
        try
        {
            var segments = new Uri(url).AbsolutePath
                .Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);

            if (segments.Length > 0)
            {
                var category = segments[0].ToLowerInvariant();
                if (new[] { "home", "soft", "maniax", "pro", "aix", "books", "appx", "app" }.Contains(category))
                    return category;
            }
        }
        catch
        {
            // Keep the original default for unrecognised URLs.
        }

        return "maniax";
    }

    private static string BuildWorkPageReferer(string url, SupportedLanguages language)
    {
        var category = GetCategoryFromUrl(url);
        return $"https://www.dlsite.com/{category}/?locale={language}";
    }

    private async Task<(string Body, string FinalUrl)> DownloadStringAsync(
        string url,
        SupportedLanguages language,
        string referer,
        bool isAjax)
    {
        const int maxAttempts = 3;
        Exception lastException = null;

        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "GET";
            request.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36";
            request.Accept = isAjax
                ? "application/json, text/javascript, */*; q=0.01"
                : "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8";
            request.Headers[HttpRequestHeader.AcceptLanguage] =
                language.ToString().Replace('_', '-') + ",ja;q=0.9,en-US;q=0.8,en;q=0.7";
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            request.Timeout = 30000;
            request.ReadWriteTimeout = 30000;
            request.AllowAutoRedirect = true;
            request.KeepAlive = true;
            request.CookieContainer = new CookieContainer();

            var baseUri = new Uri(SiteBaseUrl);
            request.CookieContainer.Add(baseUri, new Cookie("locale", language.ToString(), "/", ".dlsite.com"));
            request.CookieContainer.Add(baseUri, new Cookie("loginchecked", "1", "/", ".dlsite.com"));
            request.CookieContainer.Add(baseUri, new Cookie("adultchecked", "1", "/", ".dlsite.com"));

            if (!string.IsNullOrWhiteSpace(referer))
                request.Referer = referer;

            if (isAjax)
                request.Headers.Add("X-Requested-With", "XMLHttpRequest");

            try
            {
                using (var response = (HttpWebResponse)await request.GetResponseAsync())
                using (var stream = response.GetResponseStream())
                {
                    var encoding = Encoding.UTF8;
                    try
                    {
                        if (!string.IsNullOrWhiteSpace(response.CharacterSet))
                            encoding = Encoding.GetEncoding(response.CharacterSet.Trim('"'));
                    }
                    catch
                    {
                        encoding = Encoding.UTF8;
                    }

                    using (var reader = new StreamReader(stream, encoding, true))
                    {
                        var body = await reader.ReadToEndAsync();
                        return (body, response.ResponseUri?.ToString() ?? url);
                    }
                }
            }
            catch (WebException ex)
            {
                lastException = ex;
                var status = (ex.Response as HttpWebResponse)?.StatusCode;
                (ex.Response as HttpWebResponse)?.Dispose();

                var shouldRetry = !status.HasValue
                                  || (int)status.Value == 429
                                  || (int)status.Value >= 500;

                if (attempt >= maxAttempts || !shouldRetry)
                {
                    logger.Error(ex, $"Failed to fetch DLsite URL after {attempt} attempt(s): {url}");
                    throw new HttpRequestException($"Failed to fetch DLsite URL: {url}", ex);
                }

                logger.Warn(ex, $"DLsite request failed; retrying ({attempt}/{maxAttempts}): {url}");
                await Task.Delay(TimeSpan.FromMilliseconds(600 * attempt));
            }
        }

        throw new HttpRequestException($"DLsite request failed: {url}", lastException);
    }

    private static List<string> ParseImages
'@
$code = Replace-Once $code $jsonPattern $jsonReplacement "JSON enrichment and request helper"

# Keep the author's original description selector and content; only prevent null descriptions from aborting the entire scrape.
$descriptionPattern = '(?s)        var descriptionHtml = document\.QuerySelector\("\[itemprop=''description''\]"\)\?\.InnerHtml;\s*var description = descriptionHtml\?\.Replace\("//img\.dlsite\.jp", "https://img\.dlsite\.jp"\);\s*result\.Description = Regex\.Replace\(description\?\.Trim\(\), @"\^\\s\*\$\\n\|\\r", string\.Empty, RegexOptions\.Multiline\);'
$descriptionReplacement = @'
        var descriptionHtml = document.QuerySelector("[itemprop='description']")?.InnerHtml;
        var description = descriptionHtml?.Replace("//img.dlsite.jp", "https://img.dlsite.jp");
        result.Description = string.IsNullOrWhiteSpace(description)
            ? null
            : Regex.Replace(description.Trim(), @"^\s*$\n|\r", string.Empty, RegexOptions.Multiline);
'@
$code = Replace-Once $code $descriptionPattern $descriptionReplacement "null-safe original description extraction"

[IO.File]::WriteAllText($sourcePath, $code, (New-Object Text.UTF8Encoding($false)))

# Route entered product IDs to their original DLsite catalogue; leave all metadata mapping logic unchanged.
$provider = [IO.File]::ReadAllText($providerPath)
$oldUrl = 'var url = IsValidUrl(link) ? link : $"https://www.dlsite.com/home/work/=/product_id/{gameName}.html";'
$newUrl = 'var url = IsValidUrl(link) ? link : $"https://www.dlsite.com/{GetSiteFromProductId(gameName)}/work/=/product_id/{gameName}.html";'
if (-not $provider.Contains($oldUrl)) { throw "Could not find product-ID URL construction." }
$provider = $provider.Replace($oldUrl, $newUrl)

$provider = $provider.Replace(
    '(home|soft|maniax|pro|aix)',
    '(home|soft|maniax|pro|aix|books|appx|app)'
)

$siteMethod = @'
    private static string GetSiteFromProductId(string productId)
    {
        if (productId?.StartsWith("VJ", StringComparison.OrdinalIgnoreCase) == true)
            return "pro";

        if (productId?.StartsWith("BJ", StringComparison.OrdinalIgnoreCase) == true)
            return "books";

        return "maniax";
    }

'@
$providerAnchor = '    private static bool IsValidId(string id)'
if (-not $provider.Contains($providerAnchor)) { throw "Could not find provider validation methods." }
$provider = $provider.Replace($providerAnchor, $siteMethod + $providerAnchor)

# Preserve the original extension and only bump the package version.
$manifest = [IO.File]::ReadAllText($manifestPath)
$manifest = $manifest -replace '(?m)^Version:.*$', 'Version: 1.16.5'
[IO.File]::WriteAllText($manifestPath, $manifest, (New-Object Text.UTF8Encoding($false)))

Write-Host "Patched DLsite transport, category-aware JSON enrichment, and null-safe description handling. Original metadata selectors and field mappings were preserved."
