format:
    runic -i src/ ext/ test/

changelog:
    julia --project=.ci .ci/changelog.jl
