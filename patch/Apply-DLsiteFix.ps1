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
        var (responseBody, finalUrl) = await DownloadStringAsync(
            url,
            language,
            BuildWorkPageReferer(url, language),
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
        var (responseBody, finalSearchUrl) = await DownloadStringAsync(
            searchPageUrl,
            language,
            SiteBaseUrl,
            false
        );

'@
$code = Replace-Once $code $searchRequestPattern $searchRequestReplacement "search page request"

$searchParserPattern = '(?s)        var searchResultsTable = document\.QuerySelector\("\.work_1col_table\.n_worklist"\);.*?\n        return searchResults;\n    \}'
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
        var descriptionParts = document.QuerySelectorAll("div.work_parts");
        string description = null;

        if (descriptionParts.Length > 0)
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
$parseImagesPattern = '(?s)    private static List<string> ParseImages\(IDocument document\)\s*\{.*?\n    \}\n\}'
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
$cookieNeedle = '            request.CookieContainer.Add(baseUri, new Cookie("loginchecked", "1", "/", ".dlsite.com"));'
if (-not $code.Contains($cookieNeedle)) { throw "Could not find DLsite cookie setup." }
$code = $code.Replace(
    $cookieNeedle,
    '            request.CookieContainer.Add(baseUri, new Cookie("loginchecked", "1", "/", ".dlsite.com"))' + [Environment]::NewLine +
    '            request.CookieContainer.Add(baseUri, new Cookie("adultchecked", "1", "/", ".dlsite.com"));'
)
$code = $code.Replace(
    'Chrome/136.0.0.0 Safari/537.36',
    'Chrome/138.0.0.0 Safari/537.36'
)

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
