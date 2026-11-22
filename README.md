# source-python-runtime

Builds the Python runtime that Source.Python embeds: CPython, the compiled packages Source.Python
ships, and Boost.Python built against that exact interpreter. The output is one bundle per platform,
published as GitHub release assets and pinned by checksum in the Source.Python repository.
