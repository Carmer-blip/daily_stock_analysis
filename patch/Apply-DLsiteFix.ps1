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

# Use browser-like requests for DLsite pages and retain the final URL after redirects.
$pagePattern = '(?s)        HttpResponseMessage res;\s*try\s*\{.*?        var responseBody = await res\.Content\.ReadAsStringAsync\(\);\s*'
$pageReplacement = @'
        var (responseBody, finalUrl) = await DLsiteHttp.DownloadStringAsync(
            url,
            language,
            DLsiteHttp.BuildWorkPageReferer(url, language),
            false
        );
        result.Links.Add("DLsite", finalUrl); // for redirects

'@
$code = Replace-Once $code $pagePattern $pageReplacement "product page request"

# Search query is a path segment; escape Japanese/full-width punctuation instead of only replacing spaces.
$code = Replace-Once $code '        query = query\.Replace\(" ", "\+"\);' '        query = Uri.EscapeDataString(query?.Trim() ?? string.Empty);' "search query encoding"

$searchRequestPattern = '(?s)        var handler = new HttpClientHandler \{ UseCookies = true, CookieContainer = new CookieContainer\(\) \};\s*var baseUri = new Uri\(SiteBaseUrl\);.*?        var responseBody = await client\.GetStringAsync\(SiteBaseUrl \+ searchUrl\);\s*'
$searchRequestReplacement = @'
        var searchPageUrl = SiteBaseUrl + searchUrl;
        var (responseBody, finalSearchUrl) = await DLsiteHttp.DownloadStringAsync(
            searchPageUrl,
            language,
            SiteBaseUrl,
            false
        );

'@
$code = Replace-Once $code $searchRequestPattern $searchRequestReplacement "search page request"

$oldJsonCall = "FetchJsonInfoAsync(productId, language)"
if (-not $code.Contains($oldJsonCall)) { throw "Could not locate JSON metadata call." }
$code = $code.Replace($oldJsonCall, "FetchJsonInfoAsync(productId, language, DLsiteHttp.GetCategoryFromUrl(finalUrl))")

$jsonPattern = '(?s)    /// Fetches work_name and rating from DLsite.*?    private static List<string> ParseImages'
$jsonReplacement = @'
    /// Fetches work_name and rating from the category-specific DLsite JSON API.
    /// Accepts both the legacy object response and the newer array response.
    private async Task<(double? Rating, string WorkName)> FetchJsonInfoAsync(
        string productId,
        SupportedLanguages language,
        string category)
    {
        try
        {
            var apiUrl = $"https://www.dlsite.com/{category}/product/info/ajax?product_id={productId}&cdn_cache_min=1";
            var referer = $"https://www.dlsite.com/{category}/work/=/product_id/{productId}.html/?locale={language}";
            var (json, _) = await DLsiteHttp.DownloadStringAsync(apiUrl, language, referer, true);

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
                if (new[] { "home", "soft", "maniax", "pro", "aix", "books", "appx", "app" }.Contains(category))
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
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36";
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
$searchParserPattern = '(?s)        var searchResultsTable = document\.QuerySelector\("\.work_1col_table\.n_worklist"\);.*?return searchResults;\s*\}'
$searchParserReplacement = @'
        var searchResultsRows = document.QuerySelectorAll(
            ".work_1col_table.n_worklist tr, #search_result_list tr, .n_work_list_container tr, tr[data-list_item_product_id]"
        );
        var seenLinks = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var row in searchResultsRows)
        {
            var anchor = row.QuerySelector(".work_name a")
                         ?? row.QuerySelector("a[href*='/work/=/product_id/']");
            if (anchor == null)
                continue;

            var href = anchor.GetAttribute("href");
            if (string.IsNullOrWhiteSpace(href)
                || !Uri.TryCreate(new Uri(SiteBaseUrl), href, out var absoluteLink))
                continue;

            var link = absoluteLink.ToString();
            var title = anchor.Text().Trim();
            if (string.IsNullOrWhiteSpace(title))
                title = anchor.GetAttribute("title")?.Trim();
            if (string.IsNullOrWhiteSpace(title) || !seenLinks.Add(link))
                continue;

            var excerpt = row.QuerySelector(".work_text")?.Text().Trim()
                          ?? row.QuerySelector(".work_intro")?.Text().Trim()
                          ?? row.QuerySelector(".search_result_text")?.Text().Trim()
                          ?? string.Empty;

            searchResults.Add(new DLsiteSearchResult
            {
                Title = title,
                Link = link,
                Excerpt = excerpt
            });
        }

        // Some DLsite result layouts do not wrap each work in a table row.
        if (searchResults.Count == 0)
        {
            foreach (var anchor in document.QuerySelectorAll("a[href*='/work/=/product_id/']"))
            {
                var href = anchor.GetAttribute("href");
                if (string.IsNullOrWhiteSpace(href)
                    || !Uri.TryCreate(new Uri(SiteBaseUrl), href, out var absoluteLink))
                    continue;

                var link = absoluteLink.ToString();
                var title = anchor.Text().Trim();
                if (string.IsNullOrWhiteSpace(title))
                    title = anchor.GetAttribute("title")?.Trim();
                if (string.IsNullOrWhiteSpace(title) || !seenLinks.Add(link))
                    continue;

                searchResults.Add(new DLsiteSearchResult
                {
                    Title = title,
                    Link = link,
                    Excerpt = anchor.ParentElement?.Text().Trim() ?? string.Empty
                });
            }
        }

        logger.Info($"DLsite search parsed {searchResults.Count} result(s). URL: {finalSearchUrl}; page title: {document.Title}; HTML length: {responseBody.Length}.");
        if (searchResults.Count == 0)
            logger.Warn($"DLsite search returned no parseable product links. URL: {finalSearchUrl}; page title: {document.Title}; HTML preview: {responseBody.Substring(0, Math.Min(responseBody.Length, 400))}");

        return searchResults;
    }
'@
$code = Replace-Once $code $searchParserPattern $searchParserReplacement "search result parser"

# Extract DLsite's current structured description blocks (work_parts), with legacy/SEO fallbacks.
$descriptionPattern = '(?s)        var descriptionHtml = document\.QuerySelector\("\[itemprop=''description''\]"\)\?\.InnerHtml;.*?        result\.Description = Regex\.Replace\(description\?\.Trim\(\), @"\^\\s\*\$\\n\|\\r", string\.Empty, RegexOptions\.Multiline\);'
$descriptionReplacement = @'
        var descriptionParts = document.QuerySelectorAll("div.work_parts").ToList();
        string description = null;

        if (descriptionParts.Count > 0)
        {
            description = string.Join(
                Environment.NewLine,
                descriptionParts.Select(part => part.OuterHtml)
            );
        }
        else
        {
            description = document.QuerySelector("[itemprop='description']")?.InnerHtml;
        }

        if (string.IsNullOrWhiteSpace(description))
            description = document.QuerySelector("meta[name='description']")?.GetAttribute("content");

        if (!string.IsNullOrWhiteSpace(description))
        {
            description = description.Replace("//img.dlsite.jp", "https://img.dlsite.jp");
            result.Description = Regex.Replace(
                description.Trim(),
                @"^\s*$\n|\r",
                string.Empty,
                RegexOptions.Multiline
            );
        }
        else
        {
            logger.Warn($"DLsite description blocks were not found for {productId ?? url} ({finalUrl}).");
            result.Description = null;
        }
'@
$code = Replace-Once $code $descriptionPattern $descriptionReplacement "description extraction"

# Product images can live outside #work_left in current layouts; include slider, description, and OG image fallbacks.
$mainImagesPattern = '(?s)        var images = ParseImages\(document\);\s*        result\.MainImage = images\.FirstOrDefault\(x => x\.Contains\("_img_main"\)\);\s*        result\.Icon = result\.MainImage\?\.Replace\("_img_main", "_img_sam_mini"\);\s*        result\.ProductImages = images;'
$mainImagesReplacement = @'
        var images = ParseImages(document);
        var mainImage = images.FirstOrDefault(x => x.IndexOf("_img_main", StringComparison.OrdinalIgnoreCase) >= 0);
        if (string.IsNullOrWhiteSpace(mainImage))
            mainImage = document.QuerySelector("meta[property='og:image']")?.GetAttribute("content");

        if (!string.IsNullOrWhiteSpace(mainImage))
        {
            if (mainImage.StartsWith("//"))
                mainImage = "https:" + mainImage;
            else if (mainImage.StartsWith("/"))
                mainImage = new Uri(new Uri(SiteBaseUrl), mainImage).ToString();

            if (!images.Any(x => string.Equals(x, mainImage, StringComparison.OrdinalIgnoreCase)))
                images.Insert(0, mainImage);
        }

        result.MainImage = mainImage ?? images.FirstOrDefault();
        result.Icon = result.MainImage?.Replace("_img_main", "_img_sam_mini");
        result.ProductImages = images.Count > 0 ? images : null;
'@
$code = Replace-Once $code $mainImagesPattern $mainImagesReplacement "main and background images"

# The current page and AJAX API need the actual category, and the product slider may not be a child of #work_left.
$parseImagesPattern = '(?s)    private static List<string> ParseImages\(IDocument document\).*?\n\}'
$parseImagesReplacement = @'
    private static List<string> ParseImages(IDocument document)
    {
        var images = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var imageElements = document.QuerySelectorAll(
            "#work_left .product-slider-data [data-src], .product-slider-data [data-src], " +
            ".product-slider-data img, #work_left img, .work_parts_area img"
        );

        foreach (var element in imageElements)
        {
            var src = element.GetAttribute("data-src") ?? element.GetAttribute("src");
            if (string.IsNullOrWhiteSpace(src))
                continue;

            src = src.Trim();
            if (src.StartsWith("//"))
                src = "https:" + src;
            else if (src.StartsWith("/"))
                src = new Uri(new Uri(SiteBaseUrl), src).ToString();

            if (src.IndexOf("img.dlsite.jp", StringComparison.OrdinalIgnoreCase) < 0)
                continue;

            if (seen.Add(src))
                images.Add(src);
        }

        var ogImage = document.QuerySelector("meta[property='og:image']")?.GetAttribute("content");
        if (!string.IsNullOrWhiteSpace(ogImage))
        {
            ogImage = ogImage.StartsWith("//") ? "https:" + ogImage : ogImage;
            if (seen.Add(ogImage))
                images.Insert(0, ogImage);
        }

        return images;
    }
}
'@
$code = Replace-Once $code $parseImagesPattern $parseImagesReplacement "image parser"

# Allow additional valid DLsite site prefixes when choosing the category-specific JSON endpoint.
$code = $code.Replace(
    'new[] { "home", "soft", "maniax", "pro", "aix" }',
    'new[] { "home", "soft", "maniax", "pro", "aix", "books", "appx", "app" }'
)

# The upstream source used a separate cookie for the adult catalogue. Set it explicitly alongside locale.
# The adult catalogue cookie is added directly in DownloadStringAsync above.
$code = $code.Replace(
    'Chrome/138.0.0.0 Safari/537.36',
    'Chrome/138.0.0.0 Safari/537.36'
)



# Add the request helper as a separate type so it is never nested inside a scraper method.
$httpHelper = @'
internal static class DLsiteHttp
{
    public static string GetCategoryFromUrl(string url)
    {
        try
        {
            var segments = new Uri(url).AbsolutePath.Split(
                new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
            if (segments.Length > 0)
            {
                var category = segments[0].ToLowerInvariant();
                if (new[] { "home", "soft", "maniax", "pro", "aix", "books", "appx", "app" }.Contains(category))
                    return category;
            }
        }
        catch { }
        return "maniax";
    }

    public static string BuildWorkPageReferer(string url, SupportedLanguages language)
    {
        var category = GetCategoryFromUrl(url);
        return $"https://www.dlsite.com/{category}/?locale={language}";
    }

    public static async Task<(string Body, string FinalUrl)> DownloadStringAsync(
        string url, SupportedLanguages language, string referer, bool isAjax)
    {
        Exception lastException = null;
        for (var attempt = 1; attempt <= 3; attempt++)
        {
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = "GET";
            request.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36";
            request.Accept = isAjax
                ? "application/json, text/javascript, */*; q=0.01"
                : "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8";
            request.Headers[HttpRequestHeader.AcceptLanguage] = language.ToString().Replace('_', '-') + ",ja;q=0.9,en-US;q=0.8,en;q=0.7";
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            request.Timeout = 30000;
            request.ReadWriteTimeout = 30000;
            request.AllowAutoRedirect = true;
            request.CookieContainer = new CookieContainer();
            var baseUri = new Uri("https://www.dlsite.com/");
            request.CookieContainer.Add(baseUri, new Cookie("locale", language.ToString(), "/", ".dlsite.com"));
            request.CookieContainer.Add(baseUri, new Cookie("loginchecked", "1", "/", ".dlsite.com"));
            request.CookieContainer.Add(baseUri, new Cookie("adultchecked", "1", "/", ".dlsite.com"));
            if (!string.IsNullOrWhiteSpace(referer)) request.Referer = referer;
            if (isAjax) request.Headers.Add("X-Requested-With", "XMLHttpRequest");

            try
            {
                using (var response = (HttpWebResponse)await request.GetResponseAsync())
                using (var stream = response.GetResponseStream())
                using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                {
                    var body = await reader.ReadToEndAsync();
                    return (body, response.ResponseUri?.ToString() ?? url);
                }
            }
            catch (WebException ex)
            {
                lastException = ex;
                var status = (ex.Response as HttpWebResponse)?.StatusCode;
                (ex.Response as HttpWebResponse)?.Dispose();
                var retry = !status.HasValue || (int)status.Value == 429 || (int)status.Value >= 500;
                if (!retry || attempt == 3)
                    throw new HttpRequestException($"Failed to fetch DLsite URL: {url}", ex);
                await Task.Delay(TimeSpan.FromMilliseconds(500 * attempt));
            }
        }
        throw new HttpRequestException($"DLsite request failed: {url}", lastException);
    }
}
'@
$code += [Environment]::NewLine + $httpHelper + [Environment]::NewLine

[IO.File]::WriteAllText($sourcePath, $code, (New-Object Text.UTF8Encoding($false)))

# Fix product-code routing when a user enters an ID instead of a full product URL.
$provider = [IO.File]::ReadAllText($providerPath)
$oldUrl = 'var url = IsValidUrl(link) ? link : $"https://www.dlsite.com/home/work/=/product_id/{gameName}.html";'
$newUrl = 'var url = IsValidUrl(link) ? link : $"https://www.dlsite.com/{GetSiteFromProductId(gameName)}/work/=/product_id/{gameName}.html/";'
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

        // RJ and RE works belong to the doujin catalogue.
        return "maniax";
    }

'@
$providerAnchor = '    private static bool IsValidId(string id)'
if (-not $provider.Contains($providerAnchor)) { throw "Could not find provider validation methods." }
$provider = $provider.Replace($providerAnchor, $siteMethod + $providerAnchor)

# Keep complete exception details in Playnite's log instead of showing only a generic dialog.
$needle = '        catch (AggregateException ae)' + [Environment]::NewLine + '        {'
if (-not $provider.Contains($needle)) { throw "Could not find AggregateException handler." }
$provider = $provider.Replace(
    $needle,
    $needle + [Environment]::NewLine +
    '            Logger.Error(ae, "DLsite metadata fetch failed. GameName=''" + gameName + "''; DLsiteLink=''" + dlsiteLink + "''.");'
)
[IO.File]::WriteAllText($providerPath, $provider, (New-Object Text.UTF8Encoding($false)))

# Bump the extension version so Playnite can distinguish this build from the diagnostic build.
$manifest = [IO.File]::ReadAllText($manifestPath)
$manifest = $manifest -replace '(?m)^Version:.*$', 'Version: 1.16.4'
[IO.File]::WriteAllText($manifestPath, $manifest, (New-Object Text.UTF8Encoding($false)))

Write-Host "Patched DLsite search, category routing, description extraction, image extraction, request headers, and diagnostics."
