module Browser

#
# Imports:
#

import RelocatableFolders

#
# Export:
#

export browser

#
# `browser`:
#

"""
    browser(url)

Opens the given `url` in the default browser. When the `BROWSER` environment
variable is set to a Chromium-based browser and the platform is macOS then
`browser` attempts to reuse an open tab for that `url`, otherwise it opens a
new tab.
"""
function browser(url::AbstractString)
    ci = get(ENV, "CI", "false") == "true"
    ci && @info "CI system detected, skip opening browser."
    browser = get(ENV, "BROWSER", "")
    preferred_osx_browser = lowercase(browser) == "google chrome" ? "Google Chrome" : browser
    if Sys.isapple()
        if preferred_osx_browser in SUPPORTED_CHROMIUM_BROWSERS
            try
                ps = read(`ps cax`, String)
                opened_browser =
                    contains(ps, preferred_osx_browser) ? preferred_osx_browser : nothing
                if !isnothing(opened_browser)
                    encoded_uri = encode_uri(url)
                    cmd = `osascript $(OPEN_CHROME_SCRIPT) "$(encoded_uri)" "$(opened_browser)"`
                    return ci || success(cmd)
                end
            catch error
                @error "failed to open in chrome with apple script" error
            end
        end
        cmd = `open $url`
        ci || Base.run(cmd)
        return true
    elseif Sys.iswindows() || _IS_WSL
        cmd = `powershell.exe Start "'$url'"`
        ci || Base.run(cmd)
        return true
    elseif Sys.islinux()
        cmd = `xdg-open $url`, devnull, devnull, devnull
        ci || Base.run(cmd)
        return true
    else
        error("unsupported platform.")
    end
end

const SUPPORTED_CHROMIUM_BROWSERS = Set([
    "Google Chrome Canary",
    "Google Chrome Dev",
    "Google Chrome Beta",
    "Google Chrome",
    "Microsoft Edge",
    "Brave Browser",
    "Vivaldi",
    "Chromium",
])

const OPEN_CHROME_SCRIPT = RelocatableFolders.@path joinpath(@__DIR__, "openChrome.applescript")

const _IS_WSL =
    Sys.islinux() && let osrelease = "/proc/sys/kernel/osrelease"
        isfile(osrelease) && occursin(r"microsoft|wsl"i, read(osrelease, String))
    end

function encode_uri(uri::String)
    unescaped = "-.!~*'();,/?:@&=+\$#"
    buffer = IOBuffer()
    for char in uri
        if !isnothing(match(r"\w", string(char))) || char in unescaped
            write(buffer, char)
        else
            print(buffer, "%" * uppercase(string(codepoint(char), base = 16)))  # Percent-encode others
        end
    end
    return String(take!(buffer))
end

end
