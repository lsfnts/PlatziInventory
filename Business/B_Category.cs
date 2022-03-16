using System;
using System.Collections.Generic;
using Entities;
using DataAccess;

namespace Business
{
    public class B_Category
    {
        public static List<CategoryEntity> CategoryList() {
            using (var db = new InventoryContext())
            {
                return db.Categories.ToList();
            }
        }

        public static void CreateCategory(CategoryEntity oCategory){
            using (var db = new InventoryContext())
            {
                db.Categories.Add(oCategory);
                db.SaveChanges();
            }
        }

        public static void UpdateCategory(CategoryEntity oCategory) {
            using (var db = new InventoryContext())
            {
                db.Categories.Update(oCategory);
                db.SaveChanges();
            }
        }
    }
}