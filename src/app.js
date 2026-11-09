async function loadProducts() {

    try {

        const response = await fetch("products.json");

        if (!response.ok) {
            throw new Error("Unable to load products");
        }

        const products = await response.json();

        const productList = document.getElementById("product-list");

        productList.innerHTML = products.map(product => `

            <div class="product-card">

                <img
                    src="${product.image}"
                    alt="${product.name}"
                    loading="lazy">

                <div class="product-info">

                    <h3>${product.name}</h3>

                    <p>${product.description}</p>

                    <p class="price">
                        ₹${product.price} / ${product.unit}
                    </p>

                </div>

            </div>

        `).join("");

    } catch (error) {

        console.error(error);

        document.getElementById("product-list").textContent =
            "Unable to load products. Please try again later.";

    }
}

loadProducts();