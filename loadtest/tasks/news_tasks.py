"""News task — highest weight read endpoint."""

from conftest import NEWS_BUSINESS


def get_business_news(client) -> None:
    """GET /api/news/business-news/ — hits Qdrant vector search + Redis cache."""
    with client.get(
        NEWS_BUSINESS,
        name="[news] business news",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return
        resp.failure(f"business-news failed: {resp.status_code}")
