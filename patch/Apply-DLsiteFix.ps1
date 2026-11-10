$ErrorActionPreference = "Stop"

function Replace-Once {
    param([string]$Source, [string]$Pattern, [string]$Replacement, [string]$Label)
    $rx = [regex]::new($Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($rx.Matches($Source).Count -ne 1) {
        throw "Could not safely locate exactly one source block: $Label"
    }
    return $rx.Replace($Source, $Replacement.Replace('$', '$$'), 1)
}

$sourcePath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\DLsiteScrapper.cs"
$providerPath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\DLsiteMetadataProvider.cs"
$settingsPath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\DLsiteMetadataSettings.cs"
$viewPath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\DLsiteMetadataSettingsView.xaml"
$manifestPath = Join-Path $env:GITHUB_WORKSPACE "upstream\source\extension.yaml"

# ---------------------------------------------------------------------------
# DLsiteScrapper: keep every original parser and selector. Only unify the
# HTTP handler so the plugin can explicitly use Windows or a manual VPN proxy.
# ---------------------------------------------------------------------------
$code = [IO.File]::ReadAllText($sourcePath)

$code = Replace-Once $code 'public class DLsiteScrapper\(ILogger logger\)' 'public class DLsiteScrapper(ILogger logger, DLsiteMetadataSettings settings)' "scraper constructor settings injection"

if ($code -notmatch "using System\.Threading;") {
    $code = $code.Replace("using System.Text.RegularExpressions;", "using System.Text.RegularExpressions;" + [Environment]::NewLine + "using System.Threading;")
}

$oldHandler = 'var handler = new HttpClientHandler { UseCookies = true, CookieContainer = new CookieContainer() };'
$handlerCount = ([regex]::Matches($code, [regex]::Escape($oldHandler))).Count
if ($handlerCount -ne 3) { throw "Expected 3 original HttpClientHandler instances, found $handlerCount." }
$code = $code.Replace($oldHandler, "var handler = CreateHttpClientHandler();")

$clientLine = 'using var client = new HttpClient(handler);'
$clientCount = ([regex]::Matches($code, [regex]::Escape($clientLine))).Count
if ($clientCount -ne 3) { throw "Expected 3 HttpClient creation points, found $clientCount." }
$code = $code.Replace($clientLine, $clientLine + [Environment]::NewLine + '            await LogOutboundIpAsync(client);')

$helper = @'
    private static int _outboundIpLogged;

    private HttpClientHandler CreateHttpClientHandler()
    {
        var handler = new HttpClientHandler
        {
            UseCookies = true,
            CookieContainer = new CookieContainer(),
            UseProxy = true
        };

        var proxyMode = settings.ProxyMode ?? "Use Windows system proxy";

        if (proxyMode.Equals("Direct connection", StringComparison.OrdinalIgnoreCase))
        {
            handler.UseProxy = false;
            handler.Proxy = null;
            logger.Info("DLsite network mode: direct connection. A system-level VPN/TUN can still route this traffic.");
        }
        else if (proxyMode.Equals("Manual HTTP proxy", StringComparison.OrdinalIgnoreCase))
        {
            var proxyAddress = settings.HttpProxyAddress?.Trim();
            if (string.IsNullOrWhiteSpace(proxyAddress))
                throw new InvalidOperationException("Manual HTTP proxy is selected, but the proxy address is empty.");

            if (!proxyAddress.Contains("://"))
                proxyAddress = "http://" + proxyAddress;

            if (!Uri.TryCreate(proxyAddress, UriKind.Absolute, out var proxyUri) ||
                (proxyUri.Scheme != Uri.UriSchemeHttp && proxyUri.Scheme != Uri.UriSchemeHttps))
                throw new InvalidOperationException("Invalid HTTP proxy address. Use a value such as http://127.0.0.1:7890.");

            handler.UseProxy = true;
            handler.Proxy = new WebProxy(proxyUri);
            logger.Info($"DLsite network mode: manual HTTP proxy {proxyUri.Host}:{proxyUri.Port}.");
        }
        else
        {
            // Explicitly inherit the Windows/.NET default proxy (including a configured
            // system proxy or PAC result). Browser-only proxy extensions are not visible here.
            handler.UseProxy = true;
            handler.Proxy = WebRequest.DefaultWebProxy;

            try
            {
                var target = new Uri(SiteBaseUrl);
                var selectedProxy = handler.Proxy?.GetProxy(target);
                if (selectedProxy != null && selectedProxy != target)
                    logger.Info($"DLsite network mode: Windows system proxy {selectedProxy.Host}:{selectedProxy.Port}.");
                else
                    logger.Info("DLsite network mode: Windows system proxy selected; no explicit proxy route was returned. A system-level VPN/TUN may still route traffic.");
            }
            catch (Exception ex)
            {
                logger.Warn(ex, "Could not inspect the Windows system proxy; the .NET default proxy setting will still be used.");
            }
        }

        return handler;
    }

    private async Task LogOutboundIpAsync(HttpClient client)
    {
        if (Interlocked.CompareExchange(ref _outboundIpLogged, 1, 0) != 0)
            return;

        Exception lastException = null;

        // These checks use the exact same HttpClientHandler as the subsequent DLsite request.
        // They are diagnostic only; failure never prevents the original scrape from running.
        var endpoints = new[]
        {
            "https://ipapi.co/json/",
            "https://api.ipify.org"
        };

        foreach (var endpoint in endpoints)
        {
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(6));
                using var response = await client.GetAsync(endpoint, timeout.Token);
                response.EnsureSuccessStatusCode();

                var body = await response.Content.ReadAsStringAsync();
                if (endpoint.Contains("ipapi.co"))
                {
                    var info = JObject.Parse(body);
                    var ip = info["ip"]?.ToString();
                    var country = info["country_name"]?.ToString() ?? info["country"]?.ToString();
                    logger.Info($"DLsite plugin outbound public IP (same proxy handler): {ip ?? "unknown"}; country: {country ?? "unknown"}.");
                }
                else
                {
                    logger.Info($"DLsite plugin outbound public IP (same proxy handler): {body.Trim()}.");
                }

                return;
            }
            catch (Exception ex)
            {
                lastException = ex;
            }
        }

        Interlocked.Exchange(ref _outboundIpLogged, 0);
        if (lastException != null)
            logger.Warn(lastException, "Could not determine the DLsite plugin outbound public IP. The DLsite request will continue.");
    }

'@

$anchor = '    private static List<string> ParseImages(IDocument document)'
if (-not $code.Contains($anchor)) { throw "Could not locate ParseImages insertion point." }
$code = $code.Replace($anchor, $helper + $anchor)
[IO.File]::WriteAllText($sourcePath, $code, (New-Object Text.UTF8Encoding($false)))

# Pass the saved plugin settings into the original scraper. No metadata parsing changes.
$provider = [IO.File]::ReadAllText($providerPath)
$oldConstructor = 'var scrapper = new DLsiteScrapper(Logger);'
if (-not $provider.Contains($oldConstructor)) { throw "Could not locate original scraper constructor call." }
$provider = $provider.Replace($oldConstructor, 'var scrapper = new DLsiteScrapper(Logger, settings);')
[IO.File]::WriteAllText($providerPath, $provider, (New-Object Text.UTF8Encoding($false)))

# ---------------------------------------------------------------------------
# Settings: default to Windows system proxy; offer an optional manual HTTP
# proxy address for VPN clients that only expose a local proxy port.
# ---------------------------------------------------------------------------
$settings = [IO.File]::ReadAllText($settingsPath)

$settings = Replace-Once $settings '(?m)    private string _supportedLanguagesMappingTarget = "None";' @'
    private string _supportedLanguagesMappingTarget = "None";
    private string _proxyMode = "Use Windows system proxy";
    private string _httpProxyAddress = "";
'@ "proxy settings fields"

$settingsAnchor = '    public string SearchCategory'
$settingsProps = @'
    [DontSerialize]
    public List<string> AvailableProxyModes { get; } =
    [
        "Use Windows system proxy",
        "Manual HTTP proxy",
        "Direct connection"
    ];

    public string ProxyMode
    {
        get => _proxyMode;
        set => SetValue(ref _proxyMode, value);
    }

    public string HttpProxyAddress
    {
        get => _httpProxyAddress;
        set => SetValue(ref _httpProxyAddress, value);
    }

'@
if (-not $settings.Contains($settingsAnchor)) { throw "Could not locate settings property insertion point." }
$settings = $settings.Replace($settingsAnchor, $settingsProps + $settingsAnchor)

$verifyAnchor = '        return true;'
$verifyAddition = @'
        if (!Settings.AvailableProxyModes.Contains(Settings.ProxyMode))
            errors.Add("Selected network proxy mode is not supported.");

        if (Settings.ProxyMode == "Manual HTTP proxy")
        {
            var proxyAddress = Settings.HttpProxyAddress?.Trim();
            if (!string.IsNullOrWhiteSpace(proxyAddress) && !proxyAddress.Contains("://"))
                proxyAddress = "http://" + proxyAddress;

            if (string.IsNullOrWhiteSpace(proxyAddress) ||
                !System.Uri.TryCreate(proxyAddress, System.UriKind.Absolute, out var proxyUri) ||
                (proxyUri.Scheme != System.Uri.UriSchemeHttp && proxyUri.Scheme != System.Uri.UriSchemeHttps))
                errors.Add("Enter a valid HTTP proxy address, for example http://127.0.0.1:7890.");
        }

'@
if (([regex]::Matches($settings, [regex]::Escape($verifyAnchor))).Count -ne 1) { throw "Could not safely locate settings validation return." }
$settings = $settings.Replace($verifyAnchor, $verifyAddition + $verifyAnchor)
[IO.File]::WriteAllText($settingsPath, $settings, (New-Object Text.UTF8Encoding($false)))

# Add compact controls to the original settings view.
$view = [IO.File]::ReadAllText($viewPath)
$pageLanguageBlock = @'
        <StackPanel Orientation="Horizontal" Margin="0, 0, 0, 10">
            <TextBlock Text="Page Language:" Margin="0, 0, 5, 0" />
            <ComboBox ItemsSource="{Binding Settings.AvailableLanguages}"
                      SelectedValue="{Binding Settings.PageLanguage}" />
        </StackPanel>
'@
$proxyUi = @'
        <StackPanel Orientation="Horizontal" Margin="0, 0, 0, 10">
            <TextBlock Text="Network proxy:" Margin="0, 0, 5, 0" />
            <ComboBox Width="220"
                      ItemsSource="{Binding Settings.AvailableProxyModes}"
                      SelectedValue="{Binding Settings.ProxyMode}" />
        </StackPanel>

        <StackPanel Orientation="Horizontal" Margin="0, 0, 0, 3">
            <TextBlock Text="HTTP proxy address:" Margin="0, 0, 5, 0" />
            <TextBox Width="220"
                     Text="{Binding Settings.HttpProxyAddress, UpdateSourceTrigger=PropertyChanged}" />
        </StackPanel>
        <TextBlock Text="Manual mode example: http://127.0.0.1:7890 (HTTP proxy port, not SOCKS5)."
                   Margin="0, 0, 0, 10"
                   TextWrapping="Wrap"
                   Foreground="Gray" />
'@
if (([regex]::Matches($view, [regex]::Escape($pageLanguageBlock))).Count -ne 1) { throw "Could not locate original Page Language UI block." }
$view = $view.Replace($pageLanguageBlock, $pageLanguageBlock + $proxyUi)
[IO.File]::WriteAllText($viewPath, $view, (New-Object Text.UTF8Encoding($false)))


# ---------------------------------------------------------------------------
# Compatibility fixes discovered in the user's Playnite extensions.log:
# - DLsite product-info JSON may be an object OR an array.
# - Optional rating fields can be null.
# - Product-info AJAX endpoint must match the product's category.
# - Accept /books/ links and preserve their product IDs.
# - Do not throw when a product page has no description node.
# ---------------------------------------------------------------------------
$code = [IO.File]::ReadAllText($sourcePath)

$code = Replace-Once $code 'var \(jsonRating, jsonTitle\) = await FetchJsonInfoAsync\(productId, language\);' @'
            var apiCategory = GetApiCategory(url, productId);
            var (jsonRating, jsonTitle) = await FetchJsonInfoAsync(productId, language, apiCategory);
'@ "category-aware product info request"

$code = Replace-Once $code 'private async Task<\(double\? Rating, string WorkName\)> FetchJsonInfoAsync\(string productId,\s*SupportedLanguages language\)' 'private async Task<(double? Rating, string WorkName)> FetchJsonInfoAsync(string productId, SupportedLanguages language, string category)' "JSON method signature"

$code = Replace-Once $code '\$"https://www\.dlsite\.com/maniax/product/info/ajax\?product_id=\{productId\}&cdn_cache_min=1"' '$"https://www.dlsite.com/{category}/product/info/ajax?product_id={productId}&cdn_cache_min=1"' "category-specific JSON endpoint"

$code = Replace-Once $code 'new Uri\(\$"https://www\.dlsite\.com/maniax/work/=/product_id/\{productId\}\.html\?locale=\{language\}"\)' 'new Uri($"https://www.dlsite.com/{category}/work/=/product_id/{productId}.html?locale={language}")' "category-specific JSON referrer"

$oldJsonParse = @'
            var json = await response.Content.ReadAsStringAsync();
            var productNode = JObject.Parse(json)[productId];

            return (
                productNode?["rate_average_2dp"]?.Value<float>(),
                productNode?["work_name"]?.Value<string>()
            );
'@
$newJsonParse = @'
            var json = await response.Content.ReadAsStringAsync();
            var root = JToken.Parse(json);
            var productNode = FindProductObject(root, productId);

            if (productNode == null)
            {
                logger.Warn($"DLsite JSON response did not contain a product object for {productId}.");
                return (null, null);
            }

            double? rating = null;
            var ratingToken = productNode["rate_average_2dp"];
            if (ratingToken != null &&
                ratingToken.Type != JTokenType.Null &&
                double.TryParse(ratingToken.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsedRating))
            {
                rating = parsedRating;
            }

            var titleToken = productNode["work_name"];
            var title = titleToken == null || titleToken.Type == JTokenType.Null
                ? null
                : titleToken.ToString();

            return (rating, title);
'@
if (([regex]::Matches($code, [regex]::Escape($oldJsonParse))).Count -ne 1) {
    throw "Could not safely locate original JSON parsing block."
}
$code = $code.Replace($oldJsonParse, $newJsonParse)

$helperAnchor = '    private static List<string> ParseImages(IDocument document)'
$jsonHelpers = @'
    private static string GetApiCategory(string url, string productId)
    {
        try
        {
            var firstSegment = new Uri(url).AbsolutePath
                .Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries)
                .FirstOrDefault()?.ToLowerInvariant();

            if (!string.IsNullOrWhiteSpace(firstSegment) &&
                firstSegment != "home" &&
                new[] { "maniax", "pro", "soft", "books", "appx", "aix", "comipo" }.Contains(firstSegment))
                return firstSegment;
        }
        catch
        {
            // Fall back to the product ID prefix below.
        }

        if (productId.StartsWith("VJ", StringComparison.OrdinalIgnoreCase)) return "pro";
        if (productId.StartsWith("BJ", StringComparison.OrdinalIgnoreCase)) return "books";
        if (productId.StartsWith("RJ", StringComparison.OrdinalIgnoreCase) ||
            productId.StartsWith("RE", StringComparison.OrdinalIgnoreCase)) return "maniax";
        return "home";
    }

    private static JObject FindProductObject(JToken token, string productId)
    {
        if (token is JObject obj)
        {
            if (obj[productId] is JObject keyedProduct)
                return keyedProduct;

            var id = obj["product_id"]?.ToString()
                     ?? obj["workno"]?.ToString()
                     ?? obj["work_no"]?.ToString();

            if (string.Equals(id, productId, StringComparison.OrdinalIgnoreCase))
                return obj;

            if (obj["work_name"] != null || obj["rate_average_2dp"] != null)
                return obj;

            foreach (var property in obj.Properties())
            {
                var found = FindProductObject(property.Value, productId);
                if (found != null) return found;
            }
        }
        else if (token is JArray array)
        {
            foreach (var item in array)
            {
                var found = FindProductObject(item, productId);
                if (found != null) return found;
            }

            if (array.Count == 1 && array[0] is JObject onlyProduct)
                return onlyProduct;
        }

        return null;
    }

'@
if (-not $code.Contains($helperAnchor)) { throw "Could not locate ParseImages helper insertion point." }
$code = $code.Replace($helperAnchor, $jsonHelpers + $helperAnchor)

$oldDescription = @'
        var descriptionHtml = document.QuerySelector("[itemprop='description']")?.InnerHtml;
        var description = descriptionHtml?.Replace("//img.dlsite.jp", "https://img.dlsite.jp");
        result.Description = Regex.Replace(description?.Trim(), @"^\s*$\n|\r", string.Empty, RegexOptions.Multiline);
'@
$newDescription = @'
        var descriptionElement = document.QuerySelector("[itemprop='description']")
                                 ?? document.QuerySelector("#work_right .work_parts_area")
                                 ?? document.QuerySelector(".work_parts_area");
        var descriptionHtml = descriptionElement?.InnerHtml;
        var description = descriptionHtml?.Replace("//img.dlsite.jp", "https://img.dlsite.jp");

        if (string.IsNullOrWhiteSpace(description))
        {
            description = document.QuerySelector("meta[property='og:description']")?.GetAttribute("content")
                          ?? document.QuerySelector("meta[name='description']")?.GetAttribute("content");
        }

        result.Description = string.IsNullOrWhiteSpace(description)
            ? null
            : Regex.Replace(description.Trim(), @"^\s*$\n|\r", string.Empty, RegexOptions.Multiline);
'@
if (([regex]::Matches($code, [regex]::Escape($oldDescription))).Count -ne 1) {
    throw "Could not safely locate original description parsing block."
}
$code = $code.Replace($oldDescription, $newDescription)
[IO.File]::WriteAllText($sourcePath, $code, (New-Object Text.UTF8Encoding($false)))

# Fix provider URL recognition and route product IDs to the correct category.
$provider = [IO.File]::ReadAllText($providerPath)
$provider = Replace-Once $provider 'var url = IsValidUrl\(link\) \? link : \$"https://www\.dlsite\.com/home/work/=/product_id/\{gameName\}\.html";' @'
            var url = IsValidUrl(link)
                ? link
                : IsValidId(link)
                    ? $"https://www.dlsite.com/{GetCategoryForProductId(link)}/work/=/product_id/{link}.html"
                    : IsValidId(gameName)
                        ? $"https://www.dlsite.com/{GetCategoryForProductId(gameName)}/work/=/product_id/{gameName}.html"
                        : $"https://www.dlsite.com/home/work/=/product_id/{gameName}.html";
'@ "preserve product ID and route"

$oldCategoryPattern = '(home|soft|maniax|pro|aix)'
if (([regex]::Matches($provider, [regex]::Escape($oldCategoryPattern))).Count -ne 1) {
    throw "Could not safely locate the original DLsite URL category pattern."
}
$provider = $provider.Replace($oldCategoryPattern, '(home|soft|maniax|pro|aix|books|appx|comipo)')

$providerHelperAnchor = '    private static bool IsValidId(string id)'
$providerHelper = @'
    private static string GetCategoryForProductId(string productId)
    {
        if (productId.StartsWith("VJ", StringComparison.OrdinalIgnoreCase)) return "pro";
        if (productId.StartsWith("BJ", StringComparison.OrdinalIgnoreCase)) return "books";
        if (productId.StartsWith("RJ", StringComparison.OrdinalIgnoreCase) ||
            productId.StartsWith("RE", StringComparison.OrdinalIgnoreCase)) return "maniax";
        return "home";
    }

'@
if (-not $provider.Contains($providerHelperAnchor)) { throw "Could not locate provider ID helper insertion point." }
$provider = $provider.Replace($providerHelperAnchor, $providerHelper + $providerHelperAnchor)
[IO.File]::WriteAllText($providerPath, $provider, (New-Object Text.UTF8Encoding($false)))

# New version only; the upstream metadata fields and extraction code remain unchanged.
$manifest = [IO.File]::ReadAllText($manifestPath)
$manifest = $manifest -replace '(?m)^Version:.*$', 'Version: 1.16.3'
[IO.File]::WriteAllText($manifestPath, $manifest, (New-Object Text.UTF8Encoding($false)))

Write-Host "Applied proxy routing and outbound-IP diagnostics to the original DLsiteMetadata source. Original metadata extraction was not modified."
