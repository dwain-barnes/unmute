import os
import re
from functools import cache
from typing import Any, AsyncIterator, Protocol, cast

from mistralai import Mistral
from openai import AsyncOpenAI, OpenAI

from unmute.kyutai_constants import KYUTAI_LLM_MODEL, LLM_SERVER


async def rechunk_to_words(iterator: AsyncIterator[str]) -> AsyncIterator[str]:
    """
    Rechunk the iterator to be word-by-word instead of character-by-character.
    Otherwise the TTS doesn't know where word boundaries are and will mispronounce
    split words.

    The spaces will be included with the next word, so "foo bar baz" will be split into
    "foo", " bar", " baz".
    Multiple space-like characters will be merged to a single space.
    """
    buffer = ""
    space_re = re.compile(r"\s+")
    prefix = ""
    async for delta in iterator:
        buffer = buffer + delta
        while True:
            match = space_re.search(buffer)
            if match is None:
                break
            chunk = buffer[: match.start()]
            buffer = buffer[match.end() :]
            if chunk != "":
                yield prefix + chunk
            prefix = " "

    if buffer != "":
        yield prefix + buffer


class LLMStream(Protocol):
    async def chat_completion(
        self, messages: list[dict[str, str]]
    ) -> AsyncIterator[str]:
        """Get a chat completion from the LLM."""
        ...


class MistralStream:
    def __init__(self):
        self.current_message_index = 0
        self.mistral = Mistral(api_key=os.environ["MISTRAL_API_KEY"])

    async def chat_completion(
        self, messages: list[dict[str, str]]
    ) -> AsyncIterator[str]:
        event_stream = await self.mistral.chat.stream_async(
            model="mistral-large-latest",
            messages=cast(Any, messages),  # It's too annoying to type this properly
            temperature=1.0,
        )

        async for event in event_stream:
            delta = event.data.choices[0].delta.content
            assert isinstance(delta, str)  # make Pyright happy
            yield delta


def get_openai_client(server_url: str = LLM_SERVER) -> AsyncOpenAI:
    return AsyncOpenAI(api_key="EMPTY", base_url=server_url + "/v1")


@cache
def autoselect_model() -> str:
    if KYUTAI_LLM_MODEL is not None:
        return KYUTAI_LLM_MODEL
    client_sync = OpenAI(api_key="EMPTY", base_url=get_openai_client().base_url)
    models = client_sync.models.list()
    if len(models.data) != 1:
        raise ValueError("There are multiple models available. Please specify one.")
    return models.data[0].id


class VLLMStream:
    def __init__(
        self,
        client: AsyncOpenAI,
        temperature: float = 1.0,
    ):
        """
        If `model` is None, it will look at the available models, and if there is only
        one model, it will use that one. Otherwise, it will raise.
        """
        self.client = client
        self.model = autoselect_model()
        self.temperature = temperature

    async def chat_completion(
        self, messages: list[dict[str, str]]
    ) -> AsyncIterator[str]:
        stream = await self.client.chat.completions.create(
            model=self.model,
            messages=cast(Any, messages),  # Cast and hope for the best
            stream=True,
            temperature=self.temperature,
        )

        async with stream:
            async for chunk in stream:
                chunk_content = chunk.choices[0].delta.content
                assert isinstance(chunk_content, str)
                yield chunk_content


class OllamaStream:
    def __init__(
        self,
        client: AsyncOpenAI,
        temperature: float = 1.0,
    ):
        """
        Ollama stream implementation using OpenAI-compatible API.
        Uses the same interface as VLLMStream but connects to Ollama.
        """
        self.client = client
        self.model = autoselect_model()
        self.temperature = temperature

    async def chat_completion(
        self, messages: list[dict[str, str]]
    ) -> AsyncIterator[str]:
        try:
            stream = await self.client.chat.completions.create(
                model=self.model,
                messages=cast(Any, messages),  # Cast and hope for the best
                stream=True,
                temperature=self.temperature,
            )

            async with stream:
                async for chunk in stream:
                    if chunk.choices and chunk.choices[0].delta.content:
                        chunk_content = chunk.choices[0].delta.content
                        assert isinstance(chunk_content, str)
                        yield chunk_content
        except Exception as e:
            # Log the error and re-raise with more context
            import logging
            logger = logging.getLogger(__name__)
            logger.error(f"Error in Ollama chat completion: {e}")
            raise


def get_ollama_client(server_url: str = "http://localhost:11434") -> AsyncOpenAI:
    """Get OpenAI client configured for Ollama."""
    return AsyncOpenAI(api_key="ollama", base_url=server_url + "/v1")


@cache
def autoselect_ollama_model() -> str:
    """Auto-select Ollama model, with fallback to common models."""
    if KYUTAI_LLM_MODEL is not None:
        return KYUTAI_LLM_MODEL
    
    try:
        client_sync = OpenAI(api_key="ollama", base_url="http://localhost:11434/v1")
        models = client_sync.models.list()
        if len(models.data) >= 1:
            return models.data[0].id
        else:
            # Fallback to common Ollama models
            return "llama3.2"
    except Exception:
        # If we can't connect, return a common default
        return "llama3.2"


# Add missing constants and functions
INTERRUPTION_CHAR = "□"
USER_SILENCE_MARKER = "..."


def preprocess_messages_for_llm(messages: list[dict[str, str]]) -> list[dict[str, str]]:
    """
    Preprocess messages for LLM consumption.
    This function was missing and causing import errors.
    """
    processed_messages = []
    for message in messages:
        # Clean up the message content
        content = message.get("content", "").strip()
        if content:  # Only include non-empty messages
            processed_messages.append({
                "role": message.get("role", "user"),
                "content": content
            })
    return processed_messages