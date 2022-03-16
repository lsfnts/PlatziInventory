using System;
using System.Collections.Generic;
using Entities;
using DataAccess;

namespace Business
{
    public class B_Product
    {
        public static List<ProductEntity> ProductList()
        {
            using (var db = new InventoryContext())
            {
                return db.Products.ToList();
            }
        }

        public static ProductEntity ProductById(string id)
        {
            using (var db = new InventoryContext())
            {
                return db.Products.LastOrDefault(p=> p.ProductId == id);
            }
        }

        public static void CreateProduct(ProductEntity oProduct)
        {
            using (var db = new InventoryContext())
            {
                db.Products.Add(oProduct);
                db.SaveChanges();
            }
        }

        public static void UpdateProduct(ProductEntity oProduct)
        {
            using (var db = new InventoryContext())
            {
                db.Products.Update(oProduct);
                db.SaveChanges();
            }
        }       
    }
}