"""target_service demo code.

Demo hint (for Gate R / diff capture):
- Make an allowed change by editing this file (under src/), then commit.
- Then make a forbidden change under private/ and commit to force an R NO-GO.
"""

def normalize_amount(x: float) -> float:
    """
    Toy service logic:
    - normalize to 2 decimals
    - used by downstream settlement/reporting
    """
    # gelistirme gelistireme pirnt xyz
    return round(x, 2)


def format_receipt(amount: float) -> str:
    """
    Returns a string used in customer receipts.
    """
    return f"{normalize_amount(amount):.2f}"

# Demo: valid change under allowed path

# Demo: valid change under allowed path

# Demo: valid change under allowed path

# Demo: valid change under allowed path
