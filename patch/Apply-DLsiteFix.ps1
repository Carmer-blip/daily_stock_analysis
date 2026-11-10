$ErrorActionPreference = "Stop"
$path = Join-Path $env:GITHUB_WORKSPACE "upstream\source\DLsiteScrapper.cs"
$manifestPath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\extension.yaml"
$code = [IO.File]::ReadAllText($path)

if ($code -notmatch "using System\.IO;") {
    $code = $code.Replace("using System.Globalization;", "using System.Globalization;" + [Environment]::NewLine + "using System.IO;")
}
if ($code -notmatch "using System\.Text;") {
    $code = $code.Replace("using System.Net.Http;", "using System.Net.Http;" + [Environment]::NewLine + "using System.Text;")
}

$pagePattern = '(?s)        HttpResponseMessage res;\s*try\s*\{.*?        var responseBody = await res\.Content\.ReadAsStringAsync\(\);\s*'
$pageReplacement = @'
        var (responseBody, finalUrl) = await DownloadStringAsync(
            url,
            language,
            BuildWorkPageReferer(url, language),
            false
        );
        result.Links.Add("DLsite", finalUrl); // for redirects

'@
$pageRx = [regex]::new($pagePattern, [Text.RegularExpressions.RegexOptions]::Singleline)
if ($pageRx.Matches($code).Count -ne 1) { throw "Could not safely locate product-page request block." }
$code = $pageRx.Replace($code, $pageReplacement, 1)

$searchPattern = '(?s)        var handler = new HttpClientHandler \{ UseCookies = true, CookieContainer = new CookieContainer\(\) \};\s*var baseUri = new Uri\(SiteBaseUrl\);.*?        var responseBody = await client\.GetStringAsync\(SiteBaseUrl \+ searchUrl\);\s*'
$searchReplacement = @'
        var searchPageUrl = SiteBaseUrl + searchUrl;
        var (responseBody, _) = await DownloadStringAsync(
            searchPageUrl,
            language,
            SiteBaseUrl,
            false
        );

'@
$searchRx = [regex]::new($searchPattern, [Text.RegularExpressions.RegexOptions]::Singleline)
if ($searchRx.Matches($code).Count -ne 1) { throw "Could not safely locate search-page request block." }
$code = $searchRx.Replace($code, $searchReplacement, 1)

$oldCall = "FetchJsonInfoAsync(productId, language)"
if (-not $code.Contains($oldCall)) { throw "Could not locate JSON metadata call." }
$code = $code.Replace($oldCall, "FetchJsonInfoAsync(productId, language, GetCategoryFromUrl(url))")

$jsonPattern = '(?s)    /// Fetches work_name and rating from DLsite.*?    private static List<string> ParseImages'
$jsonReplacement = @'
    /// Fetches work_name and rating from the category-specific DLsite JSON API.
    /// Handles object, array, and missing-field responses without aborting the page scrape.
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
            JToken productNode = null;

            if (root.Type == JTokenType.Object)
            {
                var obj = (JObject)root;
                productNode = obj[productId];

                if (productNode == null && obj["work_name"] != null)
                    productNode = obj;

                if (productNode == null && obj.Properties().Count() == 1)
                    productNode = obj.Properties().First().Value;
            }
            else if (root.Type == JTokenType.Array)
            {
                foreach (var item in (JArray)root)
                {
                    if (item.Type != JTokenType.Object)
                        continue;

                    var obj = (JObject)item;
                    var nested = obj[productId];
                    if (nested != null)
                    {
                        productNode = nested;
                        break;
                    }

                    var itemId = obj["product_id"]?.ToString()
                                 ?? obj["workno"]?.ToString()
                                 ?? obj["id"]?.ToString();

                    if (string.Equals(itemId, productId, StringComparison.OrdinalIgnoreCase)
                        || obj["work_name"] != null)
                    {
                        productNode = obj;
                        break;
                    }
                }
            }

            if (productNode?.Type == JTokenType.Array)
                productNode = productNode.FirstOrDefault(x => x.Type == JTokenType.Object);

            if (productNode == null || productNode.Type != JTokenType.Object)
            {
                logger.Warn($"DLsite JSON response did not contain a product object for {productId}.");
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
            logger.Warn(ex, $"Failed to fetch or parse JSON data for {productId}");
            return (null, null);
        }
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
                if (new[] { "home", "soft", "maniax", "pro", "aix" }.Contains(category))
                    return category;
            }
        }
        catch
        {
            // Fall through to the default category.
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
            request.UserAgent =
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36";
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
                            encoding = Encoding.GetEncoding(response.CharacterSet);
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
$jsonRx = [regex]::new($jsonPattern, [Text.RegularExpressions.RegexOptions]::Singleline)
if ($jsonRx.Matches($code).Count -ne 1) { throw "Could not safely locate JSON parser block." }
$jsonReplacementForRegex = $jsonReplacement.Replace('$', '$$')
$code = $jsonRx.Replace($code, $jsonReplacementForRegex, 1)

[IO.File]::WriteAllText($path, $code, (New-Object Text.UTF8Encoding($false)))

$manifest = [IO.File]::ReadAllText($manifestPath)
$manifest = [regex]::Replace($manifest, '(?m)^Version:\s*.*
, 'Version: 1.16.3')
[IO.File]::WriteAllText($manifestPath, $manifest, (New-Object Text.UTF8Encoding($false)))

# Add full exception logging. The original provider only showed a generic dialog,
# which hid the actual inner exception from the user and from extensions.log.
$providerPath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\DLsiteMetadataProvider.cs"
$provider = [IO.File]::ReadAllText($providerPath)
$needle = '        catch (AggregateException ae)' + [Environment]::NewLine + '        {'
$replacement = '        catch (AggregateException ae)' + [Environment]::NewLine + '        {' + [Environment]::NewLine +
'            Logger.Error(ae, "DLsite metadata fetch failed. GameName=''" + gameName + "''; DLsiteLink=''" + dlsiteLink + "''.");'
if (!$provider.Contains($needle)) { throw "Could not find AggregateException handler in DLsiteMetadataProvider.cs." }
$provider = $provider.Replace($needle, $replacement)
[IO.File]::WriteAllText($providerPath, $provider, (New-Object Text.UTF8Encoding($false)))
Write-Host "Patched scraper, manifest, and diagnostic exception logging."
