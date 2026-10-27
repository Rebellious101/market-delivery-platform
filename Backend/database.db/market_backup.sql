-- Prestij Market Tam Veritabani Yedegi
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

DROP TABLE IF EXISTS `categories`;
CREATE TABLE `categories` (
  `id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(100) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=7 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

INSERT INTO `categories` (`id`, `name`) VALUES (1, 'İçecek');
INSERT INTO `categories` (`id`, `name`) VALUES (2, 'Atıştırmalık');
INSERT INTO `categories` (`id`, `name`) VALUES (3, 'Temel Gıda');
INSERT INTO `categories` (`id`, `name`) VALUES (4, 'Süt Ürünleri');
INSERT INTO `categories` (`id`, `name`) VALUES (5, 'Temizlik');
INSERT INTO `categories` (`id`, `name`) VALUES (6, 'Kahvaltılık');

DROP TABLE IF EXISTS `products`;
CREATE TABLE `products` (
  `id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(150) NOT NULL,
  `description` text,
  `price` decimal(10,2) NOT NULL,
  `category_id` int DEFAULT NULL,
  `image` varchar(255) DEFAULT NULL,
  `stock` int DEFAULT '0',
  `active` tinyint(1) DEFAULT '1',
  PRIMARY KEY (`id`),
  KEY `idx_products_cat_active` (`category_id`,`active`),
  CONSTRAINT `products_ibfk_1` FOREIGN KEY (`category_id`) REFERENCES `categories` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=54 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (1, 'Coca Cola 1LT', '1 litre Coca Cola', 47.00, 1, '08a3c0fa9a144a76a094164a0d092f21.jpg', 13, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (2, 'Fanta 1LT', '1 litre Fanta', 47.00, 1, '76155b2019394115a33f0a5ee4d4a065.png', 14, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (3, 'Ülker Çikolata', 'Sütlü çikolata', 100.00, 2, '552a8448eeff4317b7029ac1fe35a7b9.jpg', 29, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (4, 'Ekmek', 'Günlük taze ekmek', 28.00, 3, 'bfde5f6d5e84436da190d376cd70d728.jpg', 50, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (5, 'Süt 1LT', '1 litre süt', 69.00, 4, 'dc164af851674605a19d6fee47e62548.jpg', 21, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (6, 'Lays cips', '', 60.00, 2, 'b9ba1e5c395541e1a8ca65c0be153d94.jpg', 50, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (9, 'Sprite 1LT', '', 47.00, 1, '2bf9ef9db4c948a1b201612941a14279.jpg', 12, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (10, 'Coca Cola 330ml', '', 38.00, 1, '776607a08156401da14bee6d8562a565.jpg', 24, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (11, 'Fanta 330ml', '', 38.00, 1, 'e9c9f95194cc4043bc1d4045791f54cf.jpg', 24, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (12, 'Sprite 330ml', '', 38.00, 1, '837a5595a768498180eb3170308da01b.jpg', 24, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (13, 'Coca cola zero 330ml', '', 38.00, 1, '8cf93a772fac493fba7bf2e860e95dc9.jpg', 24, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (14, 'Coca Cola 200ml', '', 30.00, 1, 'd7ba1bf1b9544f0e82d63c55efe48927.jpg', 24, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (15, 'Fanta 200ml', '', 30.00, 1, '5aef1879fe034be4b492464cbdb2f60b.jpg', 24, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (16, 'Eti Crax Çubuk Kraker 85g', 'Çıtır çubuk kraker', 10.00, 2, '0db0af17c3be48f29d2fa50aac0e5a89.jpg', 400, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (17, 'Eti Hoşbeş Fındıklı 142g', 'Çıtır gofret', 32.00, 2, '32f31f9a029d49b0b1b7f1bed7f11066.webp', 160, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (18, 'Eti Popkek Çikolatalı 60g', 'Çikolata dolgulu kek', 14.00, 2, 'c85d5a2dda9f4cf2a23faa525a8fb3c8.jpg', 220, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (19, 'Eti Browni Intense 50g', 'Çikolata kaplı kek', 18.00, 2, 'c45bf7b518a141108e9d65ccb6454e77.jpg', 280, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (20, 'Eti Burçak Yulaflı Bisküvi 125g', 'Yulaflı bisküvi', 20.00, 2, 'a63009797272407baae73798e789d126.jpg', 190, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (21, 'Eti Benimo Lokmalık 150g', 'Marshmallowlu bisküvi', 30.00, 2, '0db2b3303f4d48f7aaaaf2a787d9604a.jpg', 140, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (22, 'Eti Negro Bisküvi 110g', 'Kakaolu kremalı bisküvi', 22.00, 2, '92fa970d73f0417da8fe60f3eedf9f09.jpg', 200, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (23, 'Eti Adora Çikolata 60g', 'Sütlü çikolata', 25.00, 2, 'eti_adora.png', 150, 0);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (24, 'Eti Tutku Bisküvi 100g', 'Akışkan çikolatalı bisküvi', 18.00, 2, 'd3606926d85e4879b20f95ad989b4e56.jpg', 210, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (25, 'Eti Form Mısır Patlağı 50g', 'Diyet atıştırmalık', 15.00, 2, 'eti_form.png', 180, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (26, 'Eti Gong Baharatlı 68g', 'Mısır ve pirinç patlağı', 16.00, 2, 'eti_gong.png', 230, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (27, 'Eti Topkek Limonlu 40g', 'Meyve dolgulu kek', 10.00, 2, 'topkek_limon.png', 300, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (28, 'Eti Karam %70 Kakaolu 60g', 'Bitter çikolata', 28.00, 2, 'eti_karam.png', 170, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (29, 'Eti Lifalif Yulaf Ezmesi 500g', 'Doğal yulaf ezmesi', 48.00, 2, 'lifalif.png', 110, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (30, 'Eti Canga Yer Fıstıklı 45g', 'Karamelli fıstıklı bar', 16.00, 2, 'eti_canga.png', 260, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (31, 'Eti Crax Acılı Çubuk Kraker 85g', 'Acılı çıtır kraker', 10.00, 2, 'eti_crax_aci.png', 350, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (32, 'Eti Crax Patlatılmış Mısır Aromalı 85g', 'Mısır aromalı kraker', 10.00, 2, 'eti_crax_misir.png', 300, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (33, 'Eti Balık Kraker 85g', 'Klasik balık kraker', 11.00, 2, 'eti_balik_kraker.png', 400, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (34, 'Eti Pizza Kraker 75g', 'Peynir ve baharatlı kraker', 11.00, 2, 'eti_pizza_kraker.png', 380, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (35, 'Eti Pronutra Bisküvi 175g', 'Sütlü ve vitaminli bisküvi', 22.00, 2, 'eti_pronutra.png', 160, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (36, 'Eti Burçak Fındıklı Kremalı 160g', 'Fındık kremalı yulaflı bisküvi', 28.00, 2, 'burcak_findik_krema.png', 170, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (37, 'Eti Burçak Tuzlu Zeytinli 91g', 'Zeytinli otlu tuzlu bisküvi', 22.00, 2, 'burcak_zeytinli.png', 190, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (38, 'Eti Popkek Hindistan Cevizli 60g', 'Hindistan cevizi dolgulu kek', 14.00, 2, 'popkek_hc.png', 210, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (39, 'Eti Topkek Kakaolu 40g', 'Kakaolu mini kek', 10.00, 2, 'topkek_kakao.png', 320, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (40, 'Eti Browni Gold 45g', 'Kakaolu ıslak kek', 15.00, 2, 'browni_gold.png', 250, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (41, 'Eti Browni Intense Mousse 48g', 'Krema dolgulu çikolatalı kek', 20.00, 2, 'browni_mousse.png', 220, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (42, 'Eti Paykek Şekli Şahane 285g', 'Çikolata kaplı dilim kek', 55.00, 2, 'paykek_sahane.png', 90, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (43, 'Eti Paykek Mozaik 220g', 'Mozaik desenli batun kek', 48.00, 2, 'paykek_mozaik.png', 100, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (44, 'Eti Karam Gurme 50g', 'Bitter çikolatalı gofret', 22.00, 2, 'karam_gurme.png', 260, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (45, 'Eti Dare Sütlü Çikolatalı Bar 40g', 'Sütlü gofret bar', 16.00, 2, 'eti_dare.png', 200, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (46, 'Eti Maximo Karamelli 45g', 'Karamel kaplı gevreklik bar', 14.00, 2, 'eti_maximo.png', 240, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (47, 'Eti Karam %54 Fındıklı 60g', 'Fındıklı bitter tablet çikolata', 30.00, 2, 'karam_findikli.png', 150, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (48, 'Eti Keyf-i Antep Fıstıklı 60g', 'Antep fıstıklı sütlü çikolata', 38.00, 2, 'eti_keyfi_antep.png', 129, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (49, 'Eti Lifalif Yulaf Bar Kuruyemişli 35g', 'Yulaflı kuruyemişli bar', 18.00, 2, 'lifalif_bar_kuru.png', 219, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (50, 'Eti Lifalif Yulaf Bar Kırmızı Meyveli 35g', 'Meyveli yulaflı bar', 18.00, 2, 'lifalif_bar_meyve.png', 210, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (51, 'Eti Lifalif İnce Öğütülmüş Yulaf 350g', 'Kolay hazırlanan yulaf ezmesi', 42.00, 2, 'lifalif_ince.png', 119, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (52, 'Eti Form Çikolata Kaplı Bisküvi 50g', 'Diyet çikolatalı bisküvi', 16.00, 2, 'form_cikolata.png', 180, 1);
INSERT INTO `products` (`id`, `name`, `description`, `price`, `category_id`, `image`, `stock`, `active`) VALUES (53, 'Eti Gong Sade 60g', 'Sade mısır patlağı', 15.00, 2, 'gong_sade.png', 197, 1);

DROP TABLE IF EXISTS `users`;
CREATE TABLE `users` (
  `id` int NOT NULL AUTO_INCREMENT,
  `name` varchar(120) NOT NULL,
  `email` varchar(190) NOT NULL,
  `password_hash` varchar(255) NOT NULL,
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `email` (`email`)
) ENGINE=InnoDB AUTO_INCREMENT=8 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

INSERT INTO `users` (`id`, `name`, `email`, `password_hash`, `created_at`) VALUES (2, 'Fatih Aytulun', 'fatihaytulun321@gmail.com', 'scrypt:32768:8:1$GuH9R2ztM0120IxZ$34adf8736c7aaf270c441a378c6025a78cd8be26d1a68b78d2fc5a734909abc018ef924d9bb519a1dd5905c3a4010efe86ab7d2255e9777b031f55ab73f58925', '2026-10-02 00:47:40');
INSERT INTO `users` (`id`, `name`, `email`, `password_hash`, `created_at`) VALUES (5, 'fatih ayt', 'f2561307@gmail.com', 'scrypt:32768:8:1$4djB1UQJlGNtIPgo$4d339d92667c6ec1bd99668dc7d2649ea704b95b6c4dd43f6ccc7c235a8860afe652de05547770016383302912c1d962873709f23cc7819dc100e38cf92843be', '2026-10-02 11:50:44');
INSERT INTO `users` (`id`, `name`, `email`, `password_hash`, `created_at`) VALUES (6, 'Demo User', 'test_16829de0@example.com', 'scrypt:32768:8:1$RPw2ySEeZGb0dI5k$c8f3de6239dffa3668aa3c243d86ba9b88f29f48bc582b56a56ba0a2b7a84de9bf3a28c539a053ceca29b846b1745624dca08ec2b1edf29bfeeb5295624afd15', '2026-10-02 11:54:35');

DROP TABLE IF EXISTS `user_addresses`;
CREATE TABLE `user_addresses` (
  `id` int NOT NULL AUTO_INCREMENT,
  `user_id` int NOT NULL,
  `title` varchar(50) NOT NULL,
  `full_address` text NOT NULL,
  `city` varchar(50) NOT NULL,
  `district` varchar(50) NOT NULL,
  `latitude` decimal(10,8) DEFAULT NULL,
  `longitude` decimal(11,8) DEFAULT NULL,
  `is_default` tinyint(1) DEFAULT '0',
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `user_id` (`user_id`),
  CONSTRAINT `user_addresses_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

DROP TABLE IF EXISTS `orders`;
CREATE TABLE `orders` (
  `id` int NOT NULL AUTO_INCREMENT,
  `total_price` decimal(10,2) NOT NULL,
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  `user_id` int DEFAULT NULL,
  `shipping_address` text,
  `payment_method` varchar(50) NOT NULL DEFAULT 'Nakit',
  `status` varchar(50) NOT NULL DEFAULT 'Hazırlanıyor',
  PRIMARY KEY (`id`),
  KEY `idx_orders_user_id` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=10 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

INSERT INTO `orders` (`id`, `total_price`, `created_at`, `user_id`, `shipping_address`, `payment_method`, `status`) VALUES (1, 310.00, '2026-09-11 17:31:28', NULL, NULL, 'Nakit', 'İptal Edildi');
INSERT INTO `orders` (`id`, `total_price`, `created_at`, `user_id`, `shipping_address`, `payment_method`, `status`) VALUES (2, 116.00, '2026-09-11 17:50:09', NULL, NULL, 'Nakit', 'İptal Edildi');
INSERT INTO `orders` (`id`, `total_price`, `created_at`, `user_id`, `shipping_address`, `payment_method`, `status`) VALUES (3, 47.00, '2026-09-11 18:43:47', NULL, NULL, 'Nakit', 'İptal Edildi');
INSERT INTO `orders` (`id`, `total_price`, `created_at`, `user_id`, `shipping_address`, `payment_method`, `status`) VALUES (4, 94.00, '2026-09-11 19:20:15', NULL, NULL, 'Nakit', 'İptal Edildi');
INSERT INTO `orders` (`id`, `total_price`, `created_at`, `user_id`, `shipping_address`, `payment_method`, `status`) VALUES (5, 47.00, '2026-09-14 02:50:11', NULL, NULL, 'Nakit', 'İptal Edildi');
INSERT INTO `orders` (`id`, `total_price`, `created_at`, `user_id`, `shipping_address`, `payment_method`, `status`) VALUES (6, 69.00, '2026-09-19 22:21:03', NULL, NULL, 'Nakit', 'İptal Edildi');
INSERT INTO `orders` (`id`, `total_price`, `created_at`, `user_id`, `shipping_address`, `payment_method`, `status`) VALUES (7, 69.00, '2026-09-19 22:27:00', NULL, NULL, 'Nakit', 'İptal Edildi');
INSERT INTO `orders` (`id`, `total_price`, `created_at`, `user_id`, `shipping_address`, `payment_method`, `status`) VALUES (8, 30.00, '2026-10-02 12:10:26', 5, 'Dd, Dd, Bina No: 8, Daire: 8', 'Nakit', 'Teslim Edildi');
INSERT INTO `orders` (`id`, `total_price`, `created_at`, `user_id`, `shipping_address`, `payment_method`, `status`) VALUES (9, 113.00, '2026-10-02 12:15:36', 5, 'Dd, Dd, Bina No: 8, Daire: 8', 'Nakit', 'Hazırlanıyor');

DROP TABLE IF EXISTS `order_items`;
CREATE TABLE `order_items` (
  `id` int NOT NULL AUTO_INCREMENT,
  `order_id` int NOT NULL,
  `product_id` int NOT NULL,
  `quantity` int NOT NULL,
  `price` decimal(10,2) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `product_id` (`product_id`),
  KEY `idx_order_items_order_id` (`order_id`),
  CONSTRAINT `order_items_ibfk_1` FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`) ON DELETE CASCADE,
  CONSTRAINT `order_items_ibfk_2` FOREIGN KEY (`product_id`) REFERENCES `products` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=17 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (1, 1, 1, 3, 47.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (2, 1, 3, 1, 100.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (3, 1, 5, 1, 69.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (4, 2, 1, 1, 47.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (5, 2, 5, 1, 69.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (6, 3, 1, 1, 47.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (7, 4, 1, 1, 47.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (8, 4, 2, 1, 47.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (9, 5, 1, 1, 47.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (10, 6, 5, 1, 69.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (11, 7, 5, 1, 69.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (12, 8, 53, 2, 15.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (13, 9, 53, 1, 15.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (14, 9, 51, 1, 42.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (15, 9, 49, 1, 18.00);
INSERT INTO `order_items` (`id`, `order_id`, `product_id`, `quantity`, `price`) VALUES (16, 9, 48, 1, 38.00);

DROP TABLE IF EXISTS `campaigns`;
CREATE TABLE `campaigns` (
  `id` int NOT NULL AUTO_INCREMENT,
  `title` varchar(150) NOT NULL,
  `description` text,
  `badge_text` varchar(60) DEFAULT NULL,
  `image` varchar(255) DEFAULT NULL,
  `active` tinyint(1) NOT NULL DEFAULT '1',
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

INSERT INTO `campaigns` (`id`, `title`, `description`, `badge_text`, `image`, `active`, `created_at`) VALUES (1, 'Hafta sonu indirimleri', '2000 tl\'lik alisverislerinizde 100tl lik alsiveris ceki', NULL, 'e95faeba228049af8baf49c326b1c28c.jpeg', 1, '2026-10-27 00:50:28');

SET FOREIGN_KEY_CHECKS = 1;